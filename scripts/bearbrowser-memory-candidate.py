#!/usr/bin/env python3
"""Manage BearBrowser local memory candidates with explicit commit/reject."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import secrets
import sys
from pathlib import Path
from typing import Any

SENSITIVE_RE = re.compile(r"(?i)(password|api[_-]?key|secret|token|cookie|payment|credential)")
VALID_ACTOR_TYPES = {"human", "agent", "system", "automation"}
VALID_SOURCE_KINDS = {"page", "tab", "note", "automation", "system"}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_memory_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "memory" / "candidates.jsonl"


def default_event_log() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def append_jsonl(path: Path, item: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, sort_keys=True, separators=(",", ":")) + "\n")


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


def sensitive_like(text: str) -> bool:
    return bool(SENSITIVE_RE.search(text))


def safe_text(text: str) -> str:
    if sensitive_like(text):
        return "<REDACTED-SENSITIVE-MEMORY-CANDIDATE>"
    return text


def find_memory(records: list[dict[str, Any]], memory_id: str) -> dict[str, Any]:
    for record in reversed(records):
        if record.get("memoryId") == memory_id:
            return record
    raise SystemExit(f"ERROR: memory candidate not found: {memory_id}")


def latest_candidate(records: list[dict[str, Any]]) -> dict[str, Any]:
    resolved = {str(record.get("resolvesMemoryId")) for record in records if record.get("resolvesMemoryId")}
    for record in reversed(records):
        if record.get("state") == "candidate" and record.get("memoryId") not in resolved:
            return record
    raise SystemExit("ERROR: no unresolved memory candidate found")


def event_for(memory: dict[str, Any], event_type: str, decision: str, reason: str) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.provenance.v1",
        "eventId": f"evt-{secrets.token_hex(16)}",
        "timestamp": now(),
        "product": "BearBrowser",
        "surface": "agent-sidecar",
        "profile": "bootstrap",
        "eventType": event_type,
        "actor": memory.get("actor", {"type": "system", "id": "local"}),
        "policy": {
            "decision": decision,
            "decisionId": memory.get("policy", {}).get("decisionId", f"local-{secrets.token_hex(8)}"),
            "mode": memory.get("policy", {}).get("mode", "local-default"),
            "reason": reason,
        },
        "redaction": {
            "secretValuesPresent": bool(memory.get("classification", {}).get("secretLikeDetected", False)),
            "secretValuesLogged": False,
            "payloadClass": memory.get("classification", {}).get("payloadClass", "metadata"),
        },
        "payload": {
            "memoryId": memory.get("memoryId"),
            "state": memory.get("state"),
            "sourceKind": memory.get("source", {}).get("kind", "unknown") if isinstance(memory.get("source"), dict) else "unknown",
        },
    }


def build_memory(args: argparse.Namespace) -> dict[str, Any]:
    if args.actor_type not in VALID_ACTOR_TYPES:
        raise SystemExit(f"ERROR: invalid actor type: {args.actor_type}")
    if args.source_kind not in VALID_SOURCE_KINDS:
        raise SystemExit(f"ERROR: invalid source kind: {args.source_kind}")

    found_sensitive = sensitive_like(args.text)
    payload_class = "secret-blocked" if found_sensitive else args.payload_class
    memory_id = f"mem-{secrets.token_hex(16)}"
    return {
        "schemaVersion": "bearbrowser.memory_candidate.v1",
        "memoryId": memory_id,
        "timestamp": now(),
        "product": "BearBrowser",
        "state": "candidate",
        "actor": {"type": args.actor_type, "id": args.actor_id},
        "source": {
            "kind": args.source_kind,
            **({"url": args.source_url} if args.source_url else {}),
            **({"title": args.source_title} if args.source_title else {}),
            **({"label": args.source_label} if args.source_label else {}),
        },
        "classification": {
            "payloadClass": payload_class,
            "secretLikeDetected": found_sensitive,
            "persistentWriteRequiresApproval": True,
        },
        "text": safe_text(args.text),
        "policy": {
            "decision": "hold",
            "decisionId": f"local-{secrets.token_hex(8)}",
            "mode": "local-default",
            "reason": "Memory candidates must be previewed and explicitly committed or rejected.",
        },
    }


def resolve_memory(parent: dict[str, Any], state: str, reason: str, actor_type: str, actor_id: str) -> dict[str, Any]:
    return {
        "schemaVersion": "bearbrowser.memory_candidate.v1",
        "memoryId": f"mem-{secrets.token_hex(16)}",
        "timestamp": now(),
        "product": "BearBrowser",
        "state": state,
        "resolvesMemoryId": parent.get("memoryId", "unknown"),
        "actor": {"type": actor_type, "id": actor_id},
        "source": parent.get("source", {"kind": "system"}),
        "classification": parent.get("classification", {"payloadClass": "metadata", "secretLikeDetected": False, "persistentWriteRequiresApproval": True}),
        "text": parent.get("text", ""),
        "policy": {
            "decision": "allow" if state == "committed" else "deny",
            "decisionId": f"manual-{secrets.token_hex(8)}",
            "mode": "manual",
            "reason": reason,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Manage BearBrowser local memory candidates")
    sub = parser.add_subparsers(dest="cmd", required=True)

    create = sub.add_parser("create", help="Create a held memory candidate")
    create.add_argument("--text", required=True)
    create.add_argument("--actor-type", default="human")
    create.add_argument("--actor-id", default="local-user")
    create.add_argument("--source-kind", default="note")
    create.add_argument("--source-url", default="")
    create.add_argument("--source-title", default="")
    create.add_argument("--source-label", default="")
    create.add_argument("--payload-class", default="metadata", choices=["public", "metadata", "sensitive-metadata"])
    create.add_argument("--memory-log", default=str(default_memory_log()))
    create.add_argument("--event-log", default=str(default_event_log()))

    resolve = sub.add_parser("resolve", help="Commit or reject a held memory candidate")
    resolve.add_argument("--memory-id", default="")
    resolve.add_argument("--latest-candidate", action="store_true")
    resolve.add_argument("--decision", required=True, choices=["commit", "reject"])
    resolve.add_argument("--reason", default="Manual local memory decision.")
    resolve.add_argument("--actor-type", default="human")
    resolve.add_argument("--actor-id", default="local-user")
    resolve.add_argument("--memory-log", default=str(default_memory_log()))
    resolve.add_argument("--event-log", default=str(default_event_log()))

    args = parser.parse_args()
    memory_log = Path(args.memory_log).expanduser()
    event_log = Path(args.event_log).expanduser()

    if args.cmd == "create":
        memory = build_memory(args)
        append_jsonl(memory_log, memory)
        append_jsonl(event_log, event_for(memory, "memory.candidate_created", "hold", memory["policy"]["reason"]))
        print(f"BearBrowser memory candidate written: {memory_log}")
        print(json.dumps(memory, indent=2, sort_keys=True))
        print("memory_state=hold")
        return 0

    records = read_jsonl(memory_log)
    parent = find_memory(records, args.memory_id) if args.memory_id else latest_candidate(records)
    state = "committed" if args.decision == "commit" else "rejected"
    memory = resolve_memory(parent, state, args.reason, args.actor_type, args.actor_id)
    append_jsonl(memory_log, memory)
    event_type = "memory.committed" if state == "committed" else "memory.rejected"
    append_jsonl(event_log, event_for(memory, event_type, memory["policy"]["decision"], args.reason))
    print(f"BearBrowser memory candidate resolved: {memory_log}")
    print(json.dumps(memory, indent=2, sort_keys=True))
    print(f"memory_state={state}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
