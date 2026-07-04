#!/usr/bin/env python3
"""Update the status of a BearBrowser BrowserAutomationReceipt in place."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

VALID_STATUSES = {"ended", "failed", "revoked", "orphaned", "denied"}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def receipts_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "receipts"


def resolve_receipt_path(receipt_id: str) -> Path:
    """Return the individual receipt JSON file path, accepting either the full URN or a bare UUID."""
    rdir = receipts_dir()
    # Accept full URN like urn:srcos:receipt:browser-automation:<uuid>
    if receipt_id.startswith("urn:"):
        bare = receipt_id.split(":")[-1]
    else:
        bare = receipt_id
    return rdir / f"{bare}.json"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Update the status of a BearBrowser BrowserAutomationReceipt"
    )
    parser.add_argument("--receipt-id", required=True, help="Receipt URN or bare UUID")
    parser.add_argument(
        "--status",
        required=True,
        choices=sorted(VALID_STATUSES),
        help="New status to set on the receipt",
    )
    args = parser.parse_args()

    path = resolve_receipt_path(args.receipt_id)
    if not path.exists():
        print(f"ERROR: receipt file not found: {path}", file=sys.stderr)
        return 1

    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        print(f"ERROR: invalid JSON in receipt file {path}: {exc}", file=sys.stderr)
        return 1

    if not isinstance(receipt, dict):
        print(f"ERROR: receipt file must contain a JSON object: {path}", file=sys.stderr)
        return 1

    old_status = receipt.get("status", "<unknown>")
    receipt["status"] = args.status

    timestamp = now()
    if args.status == "revoked":
        receipt["revokedAt"] = timestamp
    elif args.status in {"ended", "failed"}:
        receipt["terminatedAt"] = timestamp

    try:
        path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")
    except OSError as exc:
        print(f"ERROR: could not write updated receipt to {path}: {exc}", file=sys.stderr)
        return 1

    jsonl_path = receipts_dir() / "receipts.jsonl"
    try:
        with jsonl_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")
    except OSError as exc:
        print(f"ERROR: could not append updated receipt to receipts.jsonl: {exc}", file=sys.stderr)
        return 1

    print(f"receipt_id={receipt.get('receiptId', args.receipt_id)}")
    print(f"status={old_status} -> {args.status}")
    print(f"updated_at={timestamp}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
