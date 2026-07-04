#!/usr/bin/env python3
"""Verify BearBrowser page summary JSONL records."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REQUIRED = {
    "schemaVersion",
    "summaryId",
    "timestamp",
    "product",
    "state",
    "actor",
    "source",
    "classification",
    "summary",
    "policy",
}
VALID_STATES = {"proposed", "reviewed", "discarded"}
BLOCKED_EXCERPT = "<REDACTED-SENSITIVE-PAGE-EXCERPT>"


def default_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "summaries" / "page-summaries.jsonl"


def verify(record: dict[str, Any], line_no: int) -> list[str]:
    errors: list[str] = []
    missing = sorted(REQUIRED - set(record))
    if missing:
        errors.append(f"line {line_no}: missing fields: {', '.join(missing)}")
    if record.get("schemaVersion") != "bearbrowser.page_summary.v1":
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
        if classification.get("mutationAllowed") is not False:
            errors.append(f"line {line_no}: summaries must be read-only and mutationAllowed=false")

    summary = record.get("summary", {})
    if not isinstance(summary, dict):
        errors.append(f"line {line_no}: summary must be object")
    else:
        if not summary.get("method"):
            errors.append(f"line {line_no}: summary.method required")
        if "summaryText" not in summary or "excerpt" not in summary:
            errors.append(f"line {line_no}: summaryText and excerpt required")
        if classification.get("secretLikeDetected") is True and summary.get("excerpt") != BLOCKED_EXCERPT:
            errors.append(f"line {line_no}: sensitive summary excerpt must be blocked")

    policy = record.get("policy", {})
    if not isinstance(policy, dict):
        errors.append(f"line {line_no}: policy must be object")
    else:
        if policy.get("decision") != "observe":
            errors.append(f"line {line_no}: summaries must default to observe")
        if not policy.get("decisionId"):
            errors.append(f"line {line_no}: missing policy decisionId")

    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify BearBrowser page summary JSONL")
    parser.add_argument("--log", default=str(default_log()))
    parser.add_argument("--allow-empty", action="store_true")
    args = parser.parse_args()

    path = Path(args.log).expanduser()
    if not path.exists():
        if args.allow_empty:
            print(f"BearBrowser page summary log missing but allowed: {path}")
            return 0
        print(f"ERROR: page summary log not found: {path}", file=sys.stderr)
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
        errors.append("page summary log contains no records")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(f"BearBrowser page summary log verified: {path}")
    print(f"records={count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
