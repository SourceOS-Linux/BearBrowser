#!/usr/bin/env python3
"""Write BearBrowser policy-visible action proposals as local JSONL."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import secrets
import sys
from pathlib import Path
from typing import Any

DEFAULTS = {
    "navigate": ("low", "allow", False, "Human-initiated navigation is allowed by local default."),
    "summarize_page": ("low", "observe", False, "Summarization is observational and must not mutate page state."),
    "compare_tabs": ("medium", "hold", True, "Cross-tab context sharing requires explicit user approval."),
    "share_page_with_agent": ("medium", "hold", True, "Page visibility to agents must be explicit."),
    "request_credential": ("critical", "hold", True, "Credential access is OS-mediated and must not be inherited by agent runtime."),
    "request_autofill": ("high", "hold", True, "Autofill can reveal or submit sensitive personal data."),
    "download_file": ("medium", "hold", True, "Downloads require provenance and future file safety checks."),
    "upload_file": ("high", "hold", True, "Uploads can exfiltrate local data and require explicit approval."),
    "read_clipboard": ("high", "hold", True, "Clipboard can contain secrets or personal data."),
    "write_clipboard": ("medium", "hold", True, "Clipboard mutation must be visible to the user."),
    "run_automation": ("high", "hold", True, "Automation controls mechanisms but does not grant authority."),
    "write_memory_candidate": ("medium", "hold", True, "Memory writes must be previewable and revocable."),
    "commit_memory": ("high", "hold", True, "Committed memory changes persistent context and requires user approval."),
}

AGENT_RUNTIME_OVERRIDES = {
    "navigate": ("low", "hold", True, "Agent-runtime navigation requires user or policy approval."),
    "request_credential": ("critical", "deny", False, "Agent-runtime cannot inherit human credentials."),
    "request_autofill": ("high", "deny", False, "Agent-runtime cannot inherit human autofill."),
}

TARGET_KINDS = {"url", "tab", "page", "credential", "file", "clipboard", "memory", "automation"}
ACTOR_TYPES = {"human", "agent", "system", "automation"}
PROFILES = {"human-secure", "agent-runtime", "bootstrap", "unknown"}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_out() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def classify(action_type: str, profile: str) -> tuple[str, str, bool, str]:
    if profile == "agent-runtime" and action_type in AGENT_RUNTIME_OVERRIDES:
        return AGENT_RUNTIME_OVERRIDES[action_type]
    return DEFAULTS[action_type]


def parse_extra(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"ERROR: --extra must be valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit("ERROR: --extra must decode to a JSON object")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a BearBrowser policy-visible action proposal")
    parser.add_argument("--action-type", required=True, choices=sorted(DEFAULTS))
    parser.add_argument("--profile", default="bootstrap", choices=sorted(PROFILES))
    parser.add_argument("--actor-type", default="human", choices=sorted(ACTOR_TYPES))
    parser.add_argument("--actor-id", default="local-user")
    parser.add_argument("--actor-display-name", default="")
    parser.add_argument("--target-kind", required=True, choices=sorted(TARGET_KINDS))
    parser.add_argument("--target-url", default="")
    parser.add_argument("--target-label", default="")
    parser.add_argument("--extra", default="{}", help="Additional non-secret JSON metadata")
    parser.add_argument("--out", default=str(default_out()))
    args = parser.parse_args()

    risk_level, decision, requires_approval, reason = classify(args.action_type, args.profile)
    action_id = f"act-{secrets.token_hex(16)}"
    decision_id = f"local-{secrets.token_hex(8)}"

    target: dict[str, Any] = {"kind": args.target_kind}
    if args.target_url:
        target["url"] = args.target_url
    if args.target_label:
        target["label"] = args.target_label
    target.update(parse_extra(args.extra))

    action = {
        "schemaVersion": "bearbrowser.policy_action.v1",
        "actionId": action_id,
        "timestamp": now(),
        "actionType": args.action_type,
        "requestedBy": {
            "type": args.actor_type,
            "id": args.actor_id,
        },
        "target": target,
        "risk": {
            "level": risk_level,
            "requiresUserApproval": requires_approval,
            "reason": reason,
        },
        "decision": {
            "state": decision,
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": reason,
        },
    }
    if args.actor_display_name:
        action["requestedBy"]["displayName"] = args.actor_display_name

    out = Path(args.out).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(action, sort_keys=True, separators=(",", ":")) + "\n")

    print(f"BearBrowser policy action written: {out}")
    print(json.dumps(action, indent=2, sort_keys=True))
    if decision == "hold":
        print("action_state=hold: user or PolicyFabric approval required")
    elif decision == "deny":
        print("action_state=deny: action blocked by local default policy")
    else:
        print(f"action_state={decision}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
