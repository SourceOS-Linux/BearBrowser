#!/usr/bin/env python3
"""Verify BearBrowser local provenance event logs."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REQUIRED = {
    "schemaVersion",
    "eventId",
    "timestamp",
    "product",
    "surface",
    "profile",
    "eventType",
    "actor",
    "policy",
    "redaction",
    "payload",
}

SECRET_MARKERS = ["password", "passphrase", "secret", "token", "credential", "cookie", "authorization", "api_key", "private_key", "payment", "cvv"]


def default_log_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def contains_unredacted_secret(value: Any) -> bool:
    if isinstance(value, dict):
        for key, inner in value.items():
            lowered = str(key).lower().replace("-", "_")
            if any(marker in lowered for marker in SECRET_MARKERS):
                if inner != "<REDACTED>":
                    return True
            if contains_unredacted_secret(inner):
                return True
    elif isinstance(value, list):
        return any(contains_unredacted_secret(item) for item in value)
    return False


def verify_event(event: dict[str, Any], line_no: int) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED - set(event))
    if missing:
        errors.append(f"line {line_no}: missing fields: {', '.join(missing)}")
    if event.get("schemaVersion") != "bearbrowser.provenance.v1":
        errors.append(f"line {line_no}: invalid schemaVersion")
    if event.get("product") != "BearBrowser":
        errors.append(f"line {line_no}: invalid product")
    redaction = event.get("redaction", {})
    if not isinstance(redaction, dict):
        errors.append(f"line {line_no}: redaction must be object")
    elif redaction.get("secretValuesLogged") is not False:
        errors.append(f"line {line_no}: secretValuesLogged must be false")
    if contains_unredacted_secret(event.get("payload", {})):
        errors.append(f"line {line_no}: payload contains unredacted secret-like value")
    policy = event.get("policy", {})
    if not isinstance(policy, dict) or not policy.get("decisionId"):
        errors.append(f"line {line_no}: missing policy decisionId")
    actor = event.get("actor", {})
    if not isinstance(actor, dict) or not actor.get("id") or not actor.get("type"):
        errors.append(f"line {line_no}: invalid actor")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify BearBrowser provenance JSONL")
    parser.add_argument("--log", default=str(default_log_path()))
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    path = Path(args.log).expanduser()
    if not path.exists():
        if args.allow_empty:
            print(f"BearBrowser provenance log missing but allowed: {path}")
            return 0
        print(f"ERROR: provenance log not found: {path}", file=sys.stderr)
        return 1

    errors: list[str] = []
    count = 0
    with path.open("r", encoding="utf-8") as handle:
        for line_no, raw in enumerate(handle, 1):
            raw = raw.strip()
            if not raw:
                continue
            count += 1
            try:
                event = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"line {line_no}: invalid JSON: {exc}")
                continue
            if not isinstance(event, dict):
                errors.append(f"line {line_no}: event must be object")
                continue
            errors.extend(verify_event(event, line_no))

    if count == 0 and not args.allow_empty:
        errors.append("provenance log contains no events")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"BearBrowser provenance log verified: {path}")
    print(f"events={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
