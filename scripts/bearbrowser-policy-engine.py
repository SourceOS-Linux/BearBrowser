#!/usr/bin/env python3
"""
BearBrowser PolicyFabric Local Enforcement Engine
==================================================
This is the local enforcement layer for BearBrowser policy decisions.

It reads from `policy/local-default-actions.yaml` relative to `BEARBROWSER_HOME`
env var or the parent of this script's directory. When PolicyFabric (remote)
becomes available, it should be called first, and this script becomes the fallback.

Exit codes:
  0  — allow (or observe)
  2  — hold (pending user approval)
  3  — deny (fast-path rejection)
  1  — error

Usage:
  bearbrowser-policy-engine --action <action_type> --profile <profile> \
      [--context KEY=VALUE ...] [--dry-run]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import uuid
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

SCHEMA_VERSION = "bearbrowser.policy_decision.v1"
PRODUCT = "BearBrowser"
ENGINE = "local-default"

KNOWN_ACTIONS = {
    "navigate",
    "summarize_page",
    "compare_tabs",
    "share_page_with_agent",
    "request_credential",
    "request_autofill",
    "download_file",
    "upload_file",
    "read_clipboard",
    "write_clipboard",
    "run_automation",
    "write_memory_candidate",
    "commit_memory",
}

# Human-secure fallback defaults used when policy file can't be parsed or an
# unknown profile is requested.
HUMAN_SECURE_DEFAULTS: dict[str, dict[str, Any]] = {
    "navigate":             {"risk": "low",      "decision": "allow", "requiresUserApproval": False,  "reason": "Human-initiated navigation is allowed in human-secure and bootstrap profiles."},
    "summarize_page":       {"risk": "low",      "decision": "observe","requiresUserApproval": False, "reason": "Summarization is observational and must not mutate page state."},
    "compare_tabs":         {"risk": "medium",   "decision": "hold",  "requiresUserApproval": True,   "reason": "Cross-tab context sharing requires explicit user approval."},
    "share_page_with_agent":{"risk": "medium",   "decision": "hold",  "requiresUserApproval": True,   "reason": "Page visibility to agents must be explicit."},
    "request_credential":   {"risk": "critical", "decision": "hold",  "requiresUserApproval": True,   "reason": "Credential access is OS-mediated and must not be inherited by agent runtime."},
    "request_autofill":     {"risk": "high",     "decision": "hold",  "requiresUserApproval": True,   "reason": "Autofill can reveal or submit sensitive personal data."},
    "download_file":        {"risk": "medium",   "decision": "hold",  "requiresUserApproval": True,   "reason": "Downloads require provenance and future file safety checks."},
    "upload_file":          {"risk": "high",     "decision": "hold",  "requiresUserApproval": True,   "reason": "Uploads can exfiltrate local data and require explicit approval."},
    "read_clipboard":       {"risk": "high",     "decision": "hold",  "requiresUserApproval": True,   "reason": "Clipboard can contain secrets or personal data."},
    "write_clipboard":      {"risk": "medium",   "decision": "hold",  "requiresUserApproval": True,   "reason": "Clipboard mutation must be visible to the user."},
    "run_automation":       {"risk": "high",     "decision": "hold",  "requiresUserApproval": True,   "reason": "Automation controls mechanisms but does not grant authority."},
    "write_memory_candidate":{"risk": "medium",  "decision": "hold",  "requiresUserApproval": True,   "reason": "Memory writes must be previewable and revocable."},
    "commit_memory":        {"risk": "high",     "decision": "hold",  "requiresUserApproval": True,   "reason": "Committed memory changes persistent context and requires user approval."},
}

# ---------------------------------------------------------------------------
# YAML parser (stdlib-only, handles the specific structure of local-default-actions.yaml)
# ---------------------------------------------------------------------------

def _parse_minimal_yaml(text: str) -> dict[str, Any]:
    """
    Minimal YAML parser for the simple nested structure used in
    local-default-actions.yaml.  Handles:
      - Indented key: value pairs
      - String and boolean values
      - No lists, no anchors, no multi-line strings
    Returns a raw nested dict with all values as strings (caller coerces).
    """
    result: dict[str, Any] = {}
    stack: list[tuple[int, dict[str, Any]]] = [(-1, result)]

    for raw_line in text.splitlines():
        # Strip comments
        line = raw_line.split("#")[0].rstrip()
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        stripped = line.strip()
        if ":" not in stripped:
            continue
        key, _, val = stripped.partition(":")
        key = key.strip()
        val = val.strip()

        # Pop stack until we find a parent at a lesser indent
        while len(stack) > 1 and stack[-1][0] >= indent:
            stack.pop()

        current = stack[-1][1]
        if val:
            current[key] = val
        else:
            new_dict: dict[str, Any] = {}
            current[key] = new_dict
            stack.append((indent, new_dict))

    return result


def _coerce_bool(val: str) -> bool:
    return val.lower() in ("true", "yes", "1")


def _extract_policy(raw: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """
    Return (actions, profile_overrides) extracted from the parsed YAML dict.
    actions: {action_name: {risk, decision, requiresUserApproval, reason}}
    profile_overrides: {profile_name: {action_name: {decision, requiresUserApproval}}}
    """
    spec = raw.get("spec", {})
    raw_actions = spec.get("actions", {})
    raw_overrides = spec.get("profileOverrides", {})

    actions: dict[str, Any] = {}
    for name, fields in raw_actions.items():
        if not isinstance(fields, dict):
            continue
        actions[name] = {
            "risk": fields.get("risk", "high"),
            "decision": fields.get("decision", "hold"),
            "requiresUserApproval": _coerce_bool(str(fields.get("requiresUserApproval", "true"))),
            "reason": fields.get("reason", ""),
        }

    profile_overrides: dict[str, Any] = {}
    for profile_name, overridden_actions in raw_overrides.items():
        if not isinstance(overridden_actions, dict):
            continue
        profile_overrides[profile_name] = {}
        for action_name, fields in overridden_actions.items():
            if not isinstance(fields, dict):
                continue
            profile_overrides[profile_name][action_name] = {
                k: (_coerce_bool(str(v)) if k == "requiresUserApproval" else v)
                for k, v in fields.items()
            }

    return actions, profile_overrides


def load_policy(policy_file: Path) -> tuple[dict[str, Any], dict[str, Any]]:
    """Load and parse the policy YAML.  Tries `import yaml` first, then falls back."""
    text = policy_file.read_text(encoding="utf-8")

    try:
        import yaml  # type: ignore[import]
        raw = yaml.safe_load(text)
    except ImportError:
        raw = _parse_minimal_yaml(text)

    return _extract_policy(raw)


# ---------------------------------------------------------------------------
# Persistence paths
# ---------------------------------------------------------------------------

def policy_dir() -> Path:
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy"
    xdg = os.environ.get("XDG_STATE_HOME", "")
    if xdg:
        return Path(xdg) / "bearbrowser" / "policy"
    return Path.home() / ".local" / "state" / "bearbrowser" / "policy"


def decisions_path() -> Path:
    return policy_dir() / "decisions.jsonl"


def hold_queue_path() -> Path:
    return policy_dir() / "hold-queue.jsonl"


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def make_decision_id() -> str:
    return f"urn:srcos:policy:decision:bearbrowser:{uuid.uuid4()}"


def resolve_policy_file() -> Path:
    """Locate local-default-actions.yaml via BEARBROWSER_HOME or script parent."""
    env_home = os.environ.get("BEARBROWSER_HOME", "")
    if env_home:
        candidate = Path(env_home) / "policy" / "local-default-actions.yaml"
        if candidate.exists():
            return candidate

    script_dir = Path(__file__).resolve().parent
    repo_root = script_dir.parent
    candidate = repo_root / "policy" / "local-default-actions.yaml"
    if candidate.exists():
        return candidate

    raise FileNotFoundError(
        f"Cannot locate local-default-actions.yaml. "
        f"Set BEARBROWSER_HOME or place the file at {candidate}"
    )


def build_decision_record(
    action: str,
    profile: str,
    decision: str,
    risk: str,
    requires_approval: bool,
    reason: str,
    context: dict[str, str],
    dry_run: bool,
) -> dict[str, Any]:
    return {
        "decisionId": make_decision_id(),
        "action": action,
        "profile": profile,
        "decision": decision,
        "risk": risk,
        "requiresUserApproval": requires_approval,
        "reason": reason,
        "timestamp": now(),
        "engine": ENGINE,
        "product": PRODUCT,
        "schemaVersion": SCHEMA_VERSION,
        "context": context,
        **({"dryRun": True} if dry_run else {}),
    }


def write_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")


def parse_context(pairs: list[str]) -> dict[str, str]:
    ctx: dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            print(f"WARNING: context value {pair!r} has no '=', skipping", file=sys.stderr)
            continue
        k, _, v = pair.partition("=")
        ctx[k.strip()] = v.strip()
    return ctx


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="BearBrowser local PolicyFabric enforcement engine"
    )
    parser.add_argument("--action", required=True, help="Action type to evaluate")
    parser.add_argument("--profile", default="human-secure", help="Policy profile (e.g. agent-runtime)")
    parser.add_argument(
        "--context",
        nargs="*",
        default=[],
        metavar="KEY=VALUE",
        help="Arbitrary context metadata (URL, tabId, sessionId, …)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the decision without writing to disk",
    )
    args = parser.parse_args()

    # --- Validate action ---
    if args.action not in KNOWN_ACTIONS:
        known = ", ".join(sorted(KNOWN_ACTIONS))
        print(
            f"ERROR: Unknown action type: {args.action!r}\n"
            f"Known actions: {known}",
            file=sys.stderr,
        )
        return 1

    # --- Load policy file ---
    try:
        policy_file = resolve_policy_file()
        actions, profile_overrides = load_policy(policy_file)
    except FileNotFoundError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"ERROR: Failed to parse policy file: {exc}", file=sys.stderr)
        return 1

    # --- Resolve base action defaults ---
    # If the action isn't in the parsed file, fall back to hard-coded defaults.
    base = actions.get(args.action) or HUMAN_SECURE_DEFAULTS.get(args.action)
    if base is None:
        # Shouldn't happen since we validated action above, but be safe.
        print(f"ERROR: No policy defaults for action {args.action!r}", file=sys.stderr)
        return 1

    decision = base["decision"]
    risk = base["risk"]
    requires_approval = base["requiresUserApproval"]
    reason = base["reason"]

    # --- Apply profile overrides ---
    known_profiles = set(profile_overrides.keys()) | {"human-secure", "bootstrap", "unknown"}
    if args.profile not in known_profiles and args.profile != "human-secure":
        print(
            f"WARNING: Unknown profile {args.profile!r}. "
            f"Defaulting to human-secure (most restrictive) settings.",
            file=sys.stderr,
        )
    else:
        overrides_for_profile = profile_overrides.get(args.profile, {})
        overrides_for_action = overrides_for_profile.get(args.action, {})
        if "decision" in overrides_for_action:
            decision = overrides_for_action["decision"]
        if "requiresUserApproval" in overrides_for_action:
            requires_approval = overrides_for_action["requiresUserApproval"]

    # --- Build record ---
    context = parse_context(args.context)
    record = build_decision_record(
        action=args.action,
        profile=args.profile,
        decision=decision,
        risk=risk,
        requires_approval=requires_approval,
        reason=reason,
        context=context,
        dry_run=args.dry_run,
    )

    # --- Output ---
    print(json.dumps(record, indent=2))

    # --- Persist ---
    if not args.dry_run:
        write_jsonl(decisions_path(), record)
        if decision == "hold":
            write_jsonl(hold_queue_path(), record)

    # --- Exit code ---
    if decision == "deny":
        return 3
    if decision == "hold":
        return 2
    return 0  # allow / observe


if __name__ == "__main__":
    sys.exit(main())
