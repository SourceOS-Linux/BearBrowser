#!/usr/bin/env python3
"""Create local BearBrowser page comparison proposals with explicit inputs."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import secrets
from pathlib import Path
from typing import Any

SENSITIVE_RE = re.compile(r"(?i)(password|api[_-]?key|secret|token|cookie|credential|payment)")
VALID_ACTOR_TYPES = {"human", "agent", "system", "automation"}
VALID_KINDS = {"page", "tab", "note", "automation", "system"}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_comparison_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "comparisons" / "page-comparisons.jsonl"


def default_event_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def default_action_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n")


def load_text(value: str, file_value: str, name: str) -> str:
    if file_value:
        path = Path(file_value).expanduser()
        if not path.exists():
            raise SystemExit(f"ERROR: --{name}-text-file not found: {path}")
        return path.read_text(encoding="utf-8", errors="replace")
    if value:
        return value
    raise SystemExit(f"ERROR: pass --{name}-text or --{name}-text-file")


def sensitive_like(text: str) -> bool:
    return bool(SENSITIVE_RE.search(text))


def safe_excerpt(text: str, limit: int = 700) -> str:
    compact = " ".join(text.split())
    if sensitive_like(compact):
        return "<REDACTED-SENSITIVE-COMPARISON-EXCERPT>"
    return compact[:limit]


def word_count(excerpt: str) -> int:
    return 0 if excerpt.startswith("<REDACTED") else len(excerpt.split())


def tokens(text: str) -> set[str]:
    if sensitive_like(text):
        return set()
    return {word.lower() for word in re.findall(r"[A-Za-z][A-Za-z0-9_-]{3,}", text) if len(word) > 3}


def comparison_summary(left_text: str, right_text: str) -> str:
    if sensitive_like(left_text) or sensitive_like(right_text):
        return "Comparison withheld because one or both inputs looked sensitive."
    left = tokens(left_text)
    right = tokens(right_text)
    shared = sorted(left & right)[:12]
    left_only = sorted(left - right)[:8]
    right_only = sorted(right - left)[:8]
    if not left and not right:
        return "No comparable visible text was available."
    parts = [
        f"Shared terms: {', '.join(shared) if shared else 'none detected'}.",
        f"Left-only terms: {', '.join(left_only) if left_only else 'none detected'}.",
        f"Right-only terms: {', '.join(right_only) if right_only else 'none detected'}.",
    ]
    return " ".join(parts)


def input_record(kind: str, label: str, url: str, title: str, text: str) -> dict[str, Any]:
    excerpt = safe_excerpt(text)
    return {
        "kind": kind,
        "label": label,
        **({"url": url} if url else {}),
        **({"title": title} if title else {}),
        "excerpt": excerpt,
        "wordCount": word_count(excerpt),
    }


def action_record(args: argparse.Namespace, decision_id: str) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.policy_action.v1",
        "actionId": f"act-{secrets.token_hex(16)}",
        "timestamp": now(),
        "actionType": "compare_tabs",
        "requestedBy": {"type": args.actor_type, "id": args.actor_id},
        "target": {
            "kind": "page",
            "label": f"{args.left_label} ↔ {args.right_label}",
            **({"url": args.left_url} if args.left_url else {}),
        },
        "risk": {
            "level": "medium",
            "requiresUserApproval": True,
            "reason": "Cross-page or cross-tab comparison requires explicit selection and review.",
        },
        "decision": {
            "state": "hold",
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": "compare_tabs defaults to hold until user or PolicyFabric approval.",
        },
    }


def event_record(comparison_id: str, args: argparse.Namespace, decision_id: str, redacted: bool) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.provenance.v1",
        "eventId": f"evt-{secrets.token_hex(16)}",
        "timestamp": now(),
        "product": "BearBrowser",
        "surface": "agent-sidecar",
        "profile": "bootstrap",
        "eventType": "page.shared_with_agent",
        "actor": {"type": args.actor_type, "id": args.actor_id},
        "policy": {
            "decision": "hold",
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": "Local page comparison proposal created; comparison remains held by default.",
        },
        "redaction": {
            "secretValuesPresent": redacted,
            "secretValuesLogged": False,
            "payloadClass": "secret-blocked" if redacted else args.payload_class,
        },
        "payload": {
            "comparisonId": comparison_id,
            "leftLabel": args.left_label,
            "rightLabel": args.right_label,
            **({"leftUrl": args.left_url} if args.left_url else {}),
            **({"rightUrl": args.right_url} if args.right_url else {}),
        },
    }


def build_comparison(args: argparse.Namespace, decision_id: str) -> dict[str, Any]:
    if args.actor_type not in VALID_ACTOR_TYPES:
        raise SystemExit(f"ERROR: invalid actor type: {args.actor_type}")
    if args.left_kind not in VALID_KINDS or args.right_kind not in VALID_KINDS:
        raise SystemExit("ERROR: invalid left/right kind")

    left_text = load_text(args.left_text, args.left_text_file, "left")
    right_text = load_text(args.right_text, args.right_text_file, "right")
    redacted = sensitive_like(left_text) or sensitive_like(right_text)
    comparison_id = f"cmp-{secrets.token_hex(16)}"
    payload_class = "secret-blocked" if redacted else args.payload_class
    return {
        "schemaVersion": "bearbrowser.page_comparison.v1",
        "comparisonId": comparison_id,
        "timestamp": now(),
        "product": "BearBrowser",
        "state": "proposed",
        "actor": {"type": args.actor_type, "id": args.actor_id},
        "left": input_record(args.left_kind, args.left_label, args.left_url, args.left_title, left_text),
        "right": input_record(args.right_kind, args.right_label, args.right_url, args.right_title, right_text),
        "classification": {
            "payloadClass": payload_class,
            "secretLikeDetected": redacted,
            "mutationAllowed": False,
            "requiresExplicitSelection": True,
        },
        "comparison": {
            "summaryText": comparison_summary(left_text, right_text),
            "method": "local-extractive",
        },
        "policy": {
            "decision": "hold",
            "decisionId": decision_id,
            "mode": "local-default",
            "reason": "Page comparison proposals require explicit review and default to hold.",
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Create a BearBrowser local page comparison proposal")
    parser.add_argument("create", nargs="?", help="Create a comparison proposal")
    parser.add_argument("--left-text", default="")
    parser.add_argument("--left-text-file", default="")
    parser.add_argument("--right-text", default="")
    parser.add_argument("--right-text-file", default="")
    parser.add_argument("--left-kind", default="page", choices=sorted(VALID_KINDS))
    parser.add_argument("--right-kind", default="page", choices=sorted(VALID_KINDS))
    parser.add_argument("--left-url", default="")
    parser.add_argument("--right-url", default="")
    parser.add_argument("--left-title", default="")
    parser.add_argument("--right-title", default="")
    parser.add_argument("--left-label", default="left")
    parser.add_argument("--right-label", default="right")
    parser.add_argument("--actor-type", default="human")
    parser.add_argument("--actor-id", default="local-user")
    parser.add_argument("--payload-class", default="metadata", choices=["public", "metadata", "sensitive-metadata"])
    parser.add_argument("--comparison-log", default=str(default_comparison_log()))
    parser.add_argument("--event-log", default=str(default_event_log()))
    parser.add_argument("--action-log", default=str(default_action_log()))
    args = parser.parse_args()

    decision_id = f"local-{secrets.token_hex(8)}"
    comparison = build_comparison(args, decision_id)
    append_jsonl(Path(args.comparison_log).expanduser(), comparison)
    append_jsonl(Path(args.action_log).expanduser(), action_record(args, decision_id))
    append_jsonl(Path(args.event_log).expanduser(), event_record(comparison["comparisonId"], args, decision_id, comparison["classification"]["secretLikeDetected"]))

    print(f"BearBrowser page comparison written: {Path(args.comparison_log).expanduser()}")
    print(json.dumps(comparison, indent=2, sort_keys=True))
    print("comparison_state=hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
