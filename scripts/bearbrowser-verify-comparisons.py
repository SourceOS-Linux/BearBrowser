#!/usr/bin/env python3
"""Verify BearBrowser page comparison JSONL records."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REQUIRED = {
    "schemaVersion",
    "comparisonId",
    "timestamp",
    "product",
    "state",
    "actor",
    "left",
    "right",
    "classification",
    "comparison",
    "policy",
}
INPUT_REQUIRED = {"kind", "label", "excerpt", "wordCount"}
BLOCKED_EXCERPT = "<REDACTED-SENSITIVE-COMPARISON-EXCERPT>"


def default_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "comparisons" / "page-comparisons.jsonl"


def verify_input(value: Any, side: str, line_no: int) -> list[str]:
    errors: list[str] = []
    if not isinstance(value, dict):
        return [f"line {line_no}: {side} must be object"]
    missing = sorted(INPUT_REQUIRED - set(value))
    if missing:
        errors.append(f"line {line_no}: {side} missing fields: {', '.join(missing)}")
    if not isinstance(value.get("wordCount"), int):
        errors.append(f"line {line_no}: {side}.wordCount must be integer")
    return errors


def verify(record: dict[str, Any], line_no: int) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED - set(record))
    if missing:
        errors.append(f"line {line_no}: missing fields: {', '.join(missing)}")
    if record.get("schemaVersion") != "bearbrowser.page_comparison.v1":
        errors.append(f"line {line_no}: invalid schemaVersion")
    if record.get("product") != "BearBrowser":
        errors.append(f"line {line_no}: invalid product")
    if record.get("state") not in {"proposed", "reviewed", "discarded"}:
        errors.append(f"line {line_no}: invalid state")

    actor = record.get("actor", {})
    if not isinstance(actor, dict) or not actor.get("type") or not actor.get("id"):
        errors.append(f"line {line_no}: invalid actor")

    errors.extend(verify_input(record.get("left"), "left", line_no))
    errors.extend(verify_input(record.get("right"), "right", line_no))

    classification = record.get("classification", {})
    if not isinstance(classification, dict):
        errors.append(f"line {line_no}: classification must be object")
    else:
        if classification.get("mutationAllowed") is not False:
            errors.append(f"line {line_no}: comparisons must be read-only and mutationAllowed=false")
        if classification.get("requiresExplicitSelection") is not True:
            errors.append(f"line {line_no}: comparisons must require explicit selection")
        if classification.get("secretLikeDetected") is True:
            left = record.get("left", {}) if isinstance(record.get("left"), dict) else {}
            right = record.get("right", {}) if isinstance(record.get("right"), dict) else {}
            if BLOCKED_EXCERPT not in {left.get("excerpt"), right.get("excerpt")}:
                errors.append(f"line {line_no}: sensitive comparison excerpt must be blocked")

    comparison = record.get("comparison", {})
    if not isinstance(comparison, dict):
        errors.append(f"line {line_no}: comparison must be object")
    else:
        if not comparison.get("summaryText"):
            errors.append(f"line {line_no}: comparison.summaryText required")
        if comparison.get("method") not in {"local-extractive", "manual", "agent-proposed"}:
            errors.append(f"line {line_no}: invalid comparison.method")

    policy = record.get("policy", {})
    if not isinstance(policy, dict):
        errors.append(f"line {line_no}: policy must be object")
    else:
        if policy.get("decision") != "hold":
            errors.append(f"line {line_no}: comparisons must default to hold")
        if not policy.get("decisionId"):
            errors.append(f"line {line_no}: missing policy decisionId")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify BearBrowser page comparison JSONL")
    parser.add_argument("--log", default=str(default_log()))
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    path = Path(args.log).expanduser()
    if not path.exists():
        if args.allow_empty:
            print(f"BearBrowser page comparison log missing but allowed: {path}")
            return 0
        print(f"ERROR: page comparison log not found: {path}", file=sys.stderr)
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
        errors.append("page comparison log contains no records")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"BearBrowser page comparison log verified: {path}")
    print(f"records={count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
