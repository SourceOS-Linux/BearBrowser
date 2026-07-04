#!/usr/bin/env python3
"""Show unresolved BearBrowser governance work: held actions and pending memory."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def default_actions() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def default_memory() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "memory" / "candidates.jsonl"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
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
                records.append(item)
    return records


def unresolved_actions(actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved = set()
    for action in actions:
        target = action.get("target", {})
        if isinstance(target, dict) and target.get("resolvedFromActionId"):
            resolved.add(str(target["resolvedFromActionId"]))
    return [
        action for action in actions
        if action.get("decision", {}).get("state") == "hold"
        and str(action.get("actionId")) not in resolved
    ]


def pending_memory(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved = {str(record.get("resolvesMemoryId")) for record in records if record.get("resolvesMemoryId")}
    return [
        record for record in records
        if record.get("state") == "candidate"
        and str(record.get("memoryId")) not in resolved
    ]


def compact_action(action: dict[str, Any]) -> dict[str, Any]:
    target = action.get("target", {}) if isinstance(action.get("target"), dict) else {}
    risk = action.get("risk", {}) if isinstance(action.get("risk"), dict) else {}
    decision = action.get("decision", {}) if isinstance(action.get("decision"), dict) else {}
    return {
        "id": action.get("actionId", "unknown"),
        "type": action.get("actionType", "unknown"),
        "targetKind": target.get("kind", "unknown"),
        "targetLabel": target.get("label", ""),
        "risk": risk.get("level", "unknown"),
        "decision": decision.get("state", "unknown"),
        "timestamp": action.get("timestamp", ""),
    }


def compact_memory(memory: dict[str, Any]) -> dict[str, Any]:
    source = memory.get("source", {}) if isinstance(memory.get("source"), dict) else {}
    classification = memory.get("classification", {}) if isinstance(memory.get("classification"), dict) else {}
    text = str(memory.get("text", ""))
    if len(text) > 100:
        text = text[:97] + "..."
    return {
        "id": memory.get("memoryId", "unknown"),
        "state": memory.get("state", "unknown"),
        "sourceKind": source.get("kind", "unknown"),
        "sourceLabel": source.get("label", ""),
        "payloadClass": classification.get("payloadClass", "unknown"),
        "timestamp": memory.get("timestamp", ""),
        "text": text,
    }


def build_queue(actions_path: Path, memory_path: Path) -> dict[str, Any]:
    actions = unresolved_actions(read_jsonl(actions_path))
    memory = pending_memory(read_jsonl(memory_path))
    return {
        "product": "BearBrowser",
        "schemaVersion": "bearbrowser.governance_queue.v1",
        "heldActionCount": len(actions),
        "pendingMemoryCount": len(memory),
        "heldActions": [compact_action(action) for action in actions],
        "pendingMemory": [compact_memory(record) for record in memory],
        "commands": {
            "allowLatestHeldAction": "bearbrowser-resolve-action --latest-held --decision allow --reason 'Allowed from governance queue.'",
            "denyLatestHeldAction": "bearbrowser-resolve-action --latest-held --decision deny --reason 'Denied from governance queue.'",
            "commitLatestMemory": "bearbrowser-memory-candidate resolve --latest-candidate --decision commit --reason 'Committed from governance queue.'",
            "rejectLatestMemory": "bearbrowser-memory-candidate resolve --latest-candidate --decision reject --reason 'Rejected from governance queue.'",
        },
    }


def print_text(queue: dict[str, Any]) -> None:
    print("BearBrowser governance queue")
    print(f"heldActions={queue['heldActionCount']}")
    for action in queue["heldActions"]:
        print(f"  action {action['id']} type={action['type']} risk={action['risk']} target={action['targetKind']}:{action['targetLabel']}")
    print(f"pendingMemory={queue['pendingMemoryCount']}")
    for memory in queue["pendingMemory"]:
        print(f"  memory {memory['id']} class={memory['payloadClass']} source={memory['sourceKind']}:{memory['sourceLabel']} text={memory['text']}")
    if queue["heldActionCount"] or queue["pendingMemoryCount"]:
        print("resolutionCommands:")
        for name, command in queue["commands"].items():
            print(f"  {name}: {command}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Show BearBrowser unresolved governance queue")
    parser.add_argument("--actions", default=str(default_actions()))
    parser.add_argument("--memory", default=str(default_memory()))
    parser.add_argument("--format", choices=["text", "json"], default="text")
    parser.add_argument("--fail-on-pending", action="store_true")
    args = parser.parse_args()

    queue = build_queue(Path(args.actions).expanduser(), Path(args.memory).expanduser())
    if args.format == "json":
        print(json.dumps(queue, indent=2, sort_keys=True))
    else:
        print_text(queue)

    if args.fail_on_pending and (queue["heldActionCount"] or queue["pendingMemoryCount"]):
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
