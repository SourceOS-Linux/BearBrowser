#!/usr/bin/env python3
"""Create local read-only BearBrowser page summary proposals."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import secrets
import sys
from pathlib import Path
from typing import Any

SENSITIVE_RE = re.compile(r"(?i)(password|api[_-]?key|secret|token|cookie|credential|payment)")
VALID_ACTOR_TYPES = {"human", "agent", "system", "automation"}
VALID_SOURCE_KINDS = {"page", "tab", "note", "automation", "system"}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_summary_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "summaries" / "page-summaries.jsonl"


def default_event_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def default_action_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n")


def sensitive_like(text: str) -> bool:
    return bool(SENSITIVE_RE.search(text))


def safe_excerpt(text: str, limit: int = 900) -> str:
    compact = " ".join(text.split())
    if sensitive_like(compact):
        return "<REDACTED-SENSITIVE-PAGE-EXCERPT>"
    return compact[:limit]


def summarize_text(text: str, limit: int = 320) -> str:
    excerpt = safe_excerpt(text, limit=limit)
    if excerpt.startswith("<REDACTED"):
        return "Summary withheld because the page text looked sensitive."
    if not excerpt:
        return "No visible text was available for a local extractive summary."
    sentences = re.split(r"(?<=[.!?])\s+", excerpt)
    selected = []
    total = 0
    for sentence in sentences:
        if not sentence:
            continue
        selected.append(sentence)
        total += len(sentence)
        if total >= limit:
            break
    return " ".join(selected)[:limit]


def action_record(args: argparse.Namespace, decision_id: str) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.policy_action.v1",
        "actionId": f"act-{secrets.token_hex(16)}",
        "timestamp": now(),
        "actionType": "summarize_page",
        "requestedBy": {"type": args.actor_type, "id": args.actor_id},
        "target": {
            "kind": args.source_kind,
            **({"url": args.source_url} if args.source_url else {}),
            **({"label": args.source_label} if args.source_label else {}),
        },
        "risk": {
            "level": "low",
            "requiresUserApproval": False,
            "reason": "Read-only local extractive summary does not mutate browser state.",
        },
        "decision": {
            "state": "observe",
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": "Summarization is observational and must not mutate page state.",
        },
    }


def event_record(summary_id: str, args: argparse.Namespace, decision_id: str, redacted: bool) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.provenance.v1",
        "eventId": f"evt-{secrets.token_hex(16)}",
        "timestamp": now(),
        "product": "BearBrowser",
        "surface": "agent-sidecar",
        "profile": "bootstrap",
        "eventType": "automation.observed",
        "actor": {"type": args.actor_type, "id": args.actor_id},
        "policy": {
            "decision": "observe",
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": "Local extractive summary proposal created without mutation.",
        },
        "redaction": {
            "secretValuesPresent": redacted,
            "secretValuesLogged": False,
            "payloadClass": "secret-blocked" if redacted else args.payload_class,
        },
        "payload": {
            "summaryId": summary_id,
            "sourceKind": args.source_kind,
            **({"url": args.source_url} if args.source_url else {}),
        },
    }


def build_summary(args: argparse.Namespace, decision_id: str) -> dict[str, Any]:
    if args.actor_type not in VALID_ACTOR_TYPES:
        raise SystemExit(f"ERROR: invalid actor type: {args.actor_type}")
    if args.source_kind not in VALID_SOURCE_KINDS:
        raise SystemExit(f"ERROR: invalid source kind: {args.source_kind}")

    redacted = sensitive_like(args.text)
    summary_id = f"sum-{secrets.token_hex(16)}"
    excerpt = safe_excerpt(args.text)
    summary_text = summarize_text(args.text)
    words = 0 if excerpt.startswith("<REDACTED") else len(excerpt.split())
    payload_class = "secret-blocked" if redacted else args.payload_class
    return {
        "schemaVersion": "bearbrowser.page_summary.v1",
        "summaryId": summary_id,
        "timestamp": now(),
        "product": "BearBrowser",
        "state": "proposed",
        "actor": {"type": args.actor_type, "id": args.actor_id},
        "source": {
            "kind": args.source_kind,
            **({"url": args.source_url} if args.source_url else {}),
            **({"title": args.source_title} if args.source_title else {}),
            **({"label": args.source_label} if args.source_label else {}),
        },
        "classification": {
            "payloadClass": payload_class,
            "secretLikeDetected": redacted,
            "mutationAllowed": False,
        },
        "summary": {
            "summaryText": summary_text,
            "excerpt": excerpt,
            "wordCount": words,
            "method": "local-extractive",
        },
        "policy": {
            "decision": "observe",
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": "Read-only local extractive summary proposal. No mutation and no memory write.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a BearBrowser local page summary proposal")
    parser.add_argument("create", nargs="?", help="Create a summary proposal")
    parser.add_argument("--text", required=True)
    parser.add_argument("--actor-type", default="human")
    parser.add_argument("--actor-id", default="local-user")
    parser.add_argument("--source-kind", default="page")
    parser.add_argument("--source-url", default="")
    parser.add_argument("--source-title", default="")
    parser.add_argument("--source-label", default="")
    parser.add_argument("--payload-class", default="metadata", choices=["public", "metadata", "sensitive-metadata"])
    parser.add_argument("--summary-log", default=str(default_summary_log()))
    parser.add_argument("--event-log", default=str(default_event_log()))
    parser.add_argument("--action-log", default=str(default_action_log()))
    args = parser.parse_args()

    decision_id = f"local-{secrets.token_hex(8)}"
    summary = build_summary(args, decision_id)
    append_jsonl(Path(args.summary_log).expanduser(), summary)
    append_jsonl(Path(args.action_log).expanduser(), action_record(args, decision_id))
    append_jsonl(Path(args.event_log).expanduser(), event_record(summary["summaryId"], args, decision_id, summary["classification"]["secretLikeDetected"]))

    print(f"BearBrowser page summary written: {Path(args.summary_log).expanduser()}")
    print(json.dumps(summary, indent=2, sort_keys=True))
    print("summary_state=proposed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
