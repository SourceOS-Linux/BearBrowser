#!/usr/bin/env python3
"""Resolve held BearBrowser policy actions with auditable local records."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import secrets
import sys
from pathlib import Path
from typing import Any

VALID_DECISIONS = {"allow", "deny"}
VALID_ACTOR_TYPES = {"human", "agent", "system", "automation"}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_actions() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def default_events() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    out: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                out.append(item)
    return out


def append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n")


def find_action(actions: list[dict[str, Any]], action_id: str | None, latest_held: bool) -> dict[str, Any]:
    if action_id:
        for action in reversed(actions):
            if action.get("actionId") == action_id:
                return action
        raise SystemExit(f"ERROR: action not found: {action_id}")
    if latest_held:
        for action in reversed(actions):
            decision = action.get("decision", {})
            if isinstance(decision, dict) and decision.get("state") == "hold":
                return action
        raise SystemExit("ERROR: no held action found")
    raise SystemExit("ERROR: pass --action-id or --latest-held")


def policy_event(decision: str, decision_id: str, parent: dict[str, Any], actor_type: str, actor_id: str, reason: str) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.provenance.v1",
        "eventId": f"evt-{secrets.token_hex(16)}",
        "timestamp": now(),
        "product": "BearBrowser",
        "surface": "policy",
        "profile": "bootstrap",
        "eventType": "policy.decision",
        "actor": {
            "type": actor_type,
            "id": actor_id,
        },
        "policy": {
            "decision": decision,
            "decisionId": decision_id,
            "mode": "manual",
            "reason": reason,
        },
        "redaction": {
            "secretValuesPresent": False,
            "secretValuesLogged": False,
            "payloadClass": "metadata",
        },
        "payload": {
            "resolvedActionId": parent.get("actionId", "unknown"),
            "actionType": parent.get("actionType", "unknown"),
            "targetKind": parent.get("target", {}).get("kind", "unknown") if isinstance(parent.get("target", {}), dict) else "unknown",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Resolve a BearBrowser held policy action")
    parser.add_argument("--actions", default=str(default_actions()))
    parser.add_argument("--events", default=str(default_events()))
    parser.add_argument("--action-id", default="")
    parser.add_argument("--latest-held", action="store_true")
    parser.add_argument("--decision", required=True, choices=sorted(VALID_DECISIONS))
    parser.add_argument("--actor-type", default="human", choices=sorted(VALID_ACTOR_TYPES))
    parser.add_argument("--actor-id", default="local-user")
    parser.add_argument("--reason", default="Manual local decision.")
    args = parser.parse_args()

    actions_path = Path(args.actions).expanduser()
    events_path = Path(args.events).expanduser()
    actions = read_jsonl(actions_path)
    parent = find_action(actions, args.action_id or None, args.latest_held)

    parent_target = parent.get("target", {}) if isinstance(parent.get("target", {}), dict) else {"kind": "automation"}
    target = dict(parent_target)
    target["resolvedFromActionId"] = parent.get("actionId", "unknown")

    risk = parent.get("risk", {}) if isinstance(parent.get("risk", {}), dict) else {}
    risk_level = str(risk.get("level", "medium"))
    decision_id = f"manual-{secrets.token_hex(8)}"
    action = {
        "schemaVersion": "bearbrowser.policy_action.v1",
        "actionId": f"act-{secrets.token_hex(16)}",
        "timestamp": now(),
        "actionType": parent.get("actionType", "run_automation"),
        "requestedBy": {
            "type": args.actor_type,
            "id": args.actor_id,
        },
        "target": target,
        "risk": {
            "level": risk_level,
            "requiresUserApproval": False,
            "reason": f"Resolution of {parent.get('actionId', 'unknown')}: {args.reason}",
        },
        "decision": {
            "state": args.decision,
            "decisionId": decision_id,
            "mode": "manual",
            "reason": args.reason,
        },
    }

    append_jsonl(actions_path, action)
    append_jsonl(events_path, policy_event(args.decision, decision_id, parent, args.actor_type, args.actor_id, args.reason))

    print(f"BearBrowser policy action resolved: {actions_path}")
    print(json.dumps(action, indent=2, sort_keys=True))
    print(f"provenance_event_written={events_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
