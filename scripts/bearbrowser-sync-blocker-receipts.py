#!/usr/bin/env python3
"""Forward BearBlocker receipt entries to the provenance events pipeline.

Reads bearblocker-receipts.jsonl (written by BearBlockerPolicy.sys.mjs in
the agent-runtime profile) and emits each new block event into the main
BearBrowser events.jsonl log via bearbrowser-emit-event.py.

Maintains a cursor file so re-runs are idempotent — only unseen lines are
forwarded. Designed to be called:
  - at BearBrowser launch (one-shot catch-up)
  - by the sidecar server on a polling interval
  - as a launchctl periodic job

Usage:
  python3 scripts/bearbrowser-sync-blocker-receipts.py [--once] [--verbose]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path


def support_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser"


def receipts_path() -> Path:
    # bearblocker-receipts.jsonl lives in the agent-runtime profile dir.
    # Try known profile locations, fall back to Application Support root.
    candidates = [
        support_dir() / "Profiles" / "agent-runtime" / "bearblocker-receipts.jsonl",
        support_dir() / "bearblocker-receipts.jsonl",
    ]
    for p in candidates:
        if p.exists():
            return p
    # Return first candidate as default (will be empty, nothing to sync)
    return candidates[0]


def cursor_path() -> Path:
    return support_dir() / "provenance" / ".bearblocker-receipts-cursor"


def events_path() -> Path:
    return support_dir() / "provenance" / "events.jsonl"


def read_cursor() -> int:
    try:
        return int(cursor_path().read_text().strip())
    except (FileNotFoundError, ValueError):
        return 0


def write_cursor(pos: int) -> None:
    cursor_path().parent.mkdir(parents=True, exist_ok=True)
    cursor_path().write_text(str(pos))


def emit_event(script_dir: Path, entry: dict, events_out: Path, verbose: bool) -> bool:
    event_type = "automation.observed"
    event = entry.get("event", "")
    if event == "network_block":
        decision = "deny"
        reason = f"BearBlocker network block: {entry.get('rule', 'unknown rule')}"
        payload_class = "metadata"
    elif event == "cosmetic_applied":
        decision = "observe"
        reason = "BearBlocker cosmetic filter applied"
        payload_class = "metadata"
    else:
        decision = "observe"
        reason = f"BearBlocker event: {event}"
        payload_class = "metadata"

    payload = json.dumps({
        "url": entry.get("url", ""),
        "rule": entry.get("rule"),
        "event": event,
        "schema": entry.get("schema", ""),
    })

    cmd = [
        sys.executable,
        str(script_dir / "bearbrowser-emit-event.py"),
        "--event-type", event_type,
        "--surface", "gecko-runtime",
        "--profile", "agent-runtime",
        "--actor-type", "system",
        "--actor-id", "bearblocker",
        "--decision", decision,
        "--policy-mode", "local-default",
        "--policy-reason", reason,
        "--payload", payload,
        "--payload-class", payload_class,
        "--out", str(events_out),
    ]
    result = subprocess.run(cmd, capture_output=not verbose)
    return result.returncode == 0


def sync_once(script_dir: Path, verbose: bool) -> int:
    src = receipts_path()
    if not src.exists():
        if verbose:
            print(f"No receipts file at {src} — nothing to sync.")
        return 0

    cursor = read_cursor()
    forwarded = 0

    with src.open("rb") as f:
        f.seek(cursor)
        lines = f.read()
        new_cursor = cursor + len(lines)

    for raw in lines.splitlines():
        if not raw.strip():
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        ok = emit_event(script_dir, entry, events_path(), verbose)
        if ok:
            forwarded += 1
        elif verbose:
            print(f"warn: failed to emit event for {raw[:80]}", file=sys.stderr)

    if forwarded:
        write_cursor(new_cursor)
        if verbose:
            print(f"Forwarded {forwarded} BearBlocker receipt(s) to events.jsonl")
    return forwarded


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--once", action="store_true",
                        help="Run once and exit (default if not polling)")
    parser.add_argument("--poll", type=int, metavar="SECONDS", default=0,
                        help="Poll every N seconds (0 = run once)")
    parser.add_argument("--verbose", "-v", action="store_true")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent

    if args.poll > 0:
        while True:
            sync_once(script_dir, args.verbose)
            time.sleep(args.poll)
    else:
        sync_once(script_dir, args.verbose)
    return 0


if __name__ == "__main__":
    sys.exit(main())
