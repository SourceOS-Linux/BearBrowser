#!/usr/bin/env python3
"""Verify BearBrowser memory candidate JSONL records."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REQUIRED = {
    "schemaVersion",
    "memoryId",
    "timestamp",
    "product",
    "state",
    "actor",
    "source",
    "classification",
    "text",
    "policy",
}
VALID_STATES = {"candidate", "committed", "rejected"}
VALID_POLICY = {"hold", "allow", "deny"}
BLOCKED_TEXT = "<REDACTED-SENSITIVE-MEMORY-CANDIDATE>"


def default_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "memory" / "candidates.jsonl"


def verify(record: dict[str, Any], line_no: int) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED - set(record))
    if missing:
        errors.append(f"line {line_no}: missing fields: {', '.join(missing)}")
    if record.get("schemaVersion") != "bearbrowser.memory_candidate.v1":
        errors.append(f"line {line_no}: invalid schemaVersion")
    if record.get("product") != "BearBrowser":
        errors.append(f"line {line_no}: invalid product")
    if record.get("state") not in VALID_STATES:
        errors.append(f"line {line_no}: invalid state")

    actor = record.get("actor", {})
    if not isinstance(actor, dict) or not actor.get("type") or not actor.get("id"):
        errors.append(f"line {line_no}: invalid actor")

    source = record.get("source", {})
    if not isinstance(source, dict) or not source.get("kind"):
        errors.append(f"line {line_no}: invalid source")

    classification = record.get("classification", {})
    if not isinstance(classification, dict):
        errors.append(f"line {line_no}: classification must be object")
    else:
        if classification.get("persistentWriteRequiresApproval") is not True:
            errors.append(f"line {line_no}: persistent writes must require approval")
        if classification.get("secretLikeDetected") is True and record.get("text") != BLOCKED_TEXT:
            errors.append(f"line {line_no}: sensitive memory candidate text must be blocked")

    policy = record.get("policy", {})
    if not isinstance(policy, dict):
        errors.append(f"line {line_no}: policy must be object")
    else:
        if policy.get("decision") not in VALID_POLICY:
            errors.append(f"line {line_no}: invalid policy decision")
        if not policy.get("decisionId"):
            errors.append(f"line {line_no}: missing policy decisionId")

    state = record.get("state")
    decision = policy.get("decision") if isinstance(policy, dict) else None
    if state == "candidate" and decision != "hold":
        errors.append(f"line {line_no}: candidates must be held")
    if state == "committed" and decision != "allow":
        errors.append(f"line {line_no}: committed records must be allowed")
    if state == "rejected" and decision != "deny":
        errors.append(f"line {line_no}: rejected records must be denied")
    if state in {"committed", "rejected"} and not record.get("resolvesMemoryId"):
        errors.append(f"line {line_no}: resolved records must point to resolvesMemoryId")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify BearBrowser memory candidate JSONL")
    parser.add_argument("--log", default=str(default_log()))
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    path = Path(args.log).expanduser()
    if not path.exists():
        if args.allow_empty:
            print(f"BearBrowser memory log missing but allowed: {path}")
            return 0
        print(f"ERROR: memory log not found: {path}", file=sys.stderr)
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
                record = json.loads(raw)
            except json.JSONDecodeError as exc:
                errors.append(f"line {line_no}: invalid JSON: {exc}")
                continue
            if not isinstance(record, dict):
                errors.append(f"line {line_no}: record must be object")
                continue
            errors.extend(verify(record, line_no))

    if count == 0 and not args.allow_empty:
        errors.append("memory log contains no records")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"BearBrowser memory candidate log verified: {path}")
    print(f"records={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
