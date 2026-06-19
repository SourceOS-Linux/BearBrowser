#!/usr/bin/env python3
"""Create a BearBrowser BrowserAutomationReceipt and write it to the receipts store."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
import uuid
from pathlib import Path

SCHEMA_VERSION = "bearbrowser.browser_automation_receipt.v1"

# Default permission scope granted per transport/mode combination.
DEFAULT_SCOPE_BY_MODE = {
    "agent-runtime": ["read_dom", "click"],
    "human-secure": ["read_dom", "click", "type"],
}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def receipts_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "receipts"


def build_receipt(
    transport: str,
    mode: str,
    url: str,
    decision_id: str,
    owner: str,
    session_id: str,
) -> dict:
    receipt_uuid = str(uuid.uuid4())
    receipt_id = f"urn:srcos:receipt:browser-automation:{receipt_uuid}"
    session_ref = f"urn:srcos:session:browser:{session_id}"

    if owner == "human":
        owner_ref = f"urn:srcos:human:{owner}"
    else:
        owner_ref = f"urn:srcos:agent:{owner}"

    policy_decision_ref = f"urn:srcos:policy:decision:bearbrowser:{decision_id}"
    permission_scope = DEFAULT_SCOPE_BY_MODE.get(mode, ["read_dom", "click"])

    receipt = {
        "schemaVersion": SCHEMA_VERSION,
        "receiptId": receipt_id,
        "sessionRef": session_ref,
        "ownerRef": owner_ref,
        "transport": transport,
        "permissionScope": permission_scope,
        "origin": "local",
        "userVisible": True,
        "revocable": True,
        "policyDecisionRef": policy_decision_ref,
        "evidenceRefs": [],
        "capturedAt": now(),
        "status": "active",
        "displayName": f"BearBrowser {mode} session ({url})",
    }
    return receipt


def write_receipt(receipt: dict) -> None:
    rdir = receipts_dir()
    rdir.mkdir(parents=True, exist_ok=True)

    receipt_id = receipt["receiptId"]
    # Extract UUID from the end of the URN for use as filename.
    receipt_uuid = receipt_id.split(":")[-1]
    individual_path = rdir / f"{receipt_uuid}.json"
    individual_path.write_text(json.dumps(receipt, indent=2, sort_keys=True), encoding="utf-8")

    jsonl_path = rdir / "receipts.jsonl"
    with jsonl_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create a BearBrowser BrowserAutomationReceipt"
    )
    parser.add_argument(
        "--transport",
        required=True,
        choices=["cdp", "native_pipe", "webdriver", "extension", "accessibility"],
    )
    parser.add_argument(
        "--mode",
        required=True,
        choices=["agent-runtime", "human-secure"],
    )
    parser.add_argument("--url", default="about:blank", help="Target URL for this session")
    parser.add_argument("--decision-id", required=True, help="Policy decision ID (BEARBROWSER_POLICY_DECISION_ID)")
    parser.add_argument(
        "--owner",
        required=True,
        help='Agent ID or "human" for the session owner',
    )
    parser.add_argument(
        "--session-id",
        default="",
        help="Session UUID (generated if absent)",
    )
    args = parser.parse_args()

    session_id = args.session_id if args.session_id else str(uuid.uuid4())

    try:
        receipt = build_receipt(
            transport=args.transport,
            mode=args.mode,
            url=args.url,
            decision_id=args.decision_id,
            owner=args.owner,
            session_id=session_id,
        )
        write_receipt(receipt)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: failed to create receipt: {exc}", file=sys.stderr)
        return 1

    receipt_uuid = receipt["receiptId"].split(":")[-1]
    receipt_path = receipts_dir() / f"{receipt_uuid}.json"
    print(receipt["receiptId"])
    print(f"receipt_path={receipt_path}")
    print(f"session_ref={receipt['sessionRef']}")
    print(f"owner_ref={receipt['ownerRef']}")
    print(f"transport={receipt['transport']}")
    print(f"status={receipt['status']}")
    print(f"captured_at={receipt['capturedAt']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
