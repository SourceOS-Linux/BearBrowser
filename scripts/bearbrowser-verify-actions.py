#!/usr/bin/env python3
"""Verify BearBrowser policy action JSONL records."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REQUIRED = {"schemaVersion", "actionId", "timestamp", "actionType", "requestedBy", "target", "risk", "decision"}
VALID_STATES = {"allow", "deny", "hold", "observe", "not_evaluated"}


def default_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def verify(action: dict[str, Any], line_no: int) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED - set(action))
    if missing:
        errors.append(f"line {line_no}: missing fields: {', '.join(missing)}")
    if action.get("schemaVersion") != "bearbrowser.policy_action.v1":
        errors.append(f"line {line_no}: invalid schemaVersion")
    decision = action.get("decision", {})
    if not isinstance(decision, dict):
        errors.append(f"line {line_no}: decision must be object")
    else:
        if decision.get("state") not in VALID_STATES:
            errors.append(f"line {line_no}: invalid decision state")
        if not decision.get("decisionId"):
            errors.append(f"line {line_no}: missing decisionId")
    risk = action.get("risk", {})
    if not isinstance(risk, dict) or not risk.get("level"):
        errors.append(f"line {line_no}: invalid risk")
    target = action.get("target", {})
    if not isinstance(target, dict) or not target.get("kind"):
        errors.append(f"line {line_no}: invalid target")
    actor = action.get("requestedBy", {})
    if not isinstance(actor, dict) or not actor.get("type") or not actor.get("id"):
        errors.append(f"line {line_no}: invalid requestedBy")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify BearBrowser policy action JSONL")
    parser.add_argument("--log", default=str(default_log()))
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    path = Path(args.log).expanduser()
    if not path.exists():
        if args.allow_empty:
            print(f"BearBrowser policy action log missing but allowed: {path}")
            return 0
        print(f"ERROR: policy action log not found: {path}", file=sys.stderr)
        return 1

    count = 0
    errors: list[str] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, 1):
            raw = raw.strip()
            if not raw:
                continue
            count += 1
            try:
                action = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"line {line_no}: invalid JSON: {exc}")
                continue
            if not isinstance(action, dict):
                errors.append(f"line {line_no}: action must be object")
                continue
            errors.extend(verify(action, line_no))

    if count == 0 and not args.allow_empty:
        errors.append("policy action log contains no actions")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"BearBrowser policy action log verified: {path}")
    print(f"actions={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
