#!/usr/bin/env python3
"""Verify BearBrowser BrowserAutomationReceipt files against the schema contract.

Covers acceptance-criteria test cases:
  - successful local automation (active receipt, valid fields)
  - denied policy decision (status=denied)
  - missing owner (ownerRef absent or empty)
  - revoked session (status=revoked, revokedAt present)
  - orphan event (no matching receipt)
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = "bearbrowser.browser_automation_receipt.v1"
RECEIPT_ID_PATTERN = re.compile(r"^urn:srcos:receipt:browser-automation:[a-zA-Z0-9_-]+$")
VALID_TRANSPORTS = {"native_pipe", "cdp", "webdriver", "extension", "accessibility"}
VALID_PERMISSIONS = {
    "read_dom", "click", "type", "download", "upload",
    "inspect_network", "inspect_cookies", "use_credentials",
}
VALID_ORIGINS = {"local", "remote", "workspace"}
VALID_STATUSES = {"active", "revoked", "ended", "denied", "orphaned"}

REQUIRED_FIELDS = {
    "schemaVersion",
    "receiptId",
    "sessionRef",
    "ownerRef",
    "transport",
    "permissionScope",
    "origin",
    "userVisible",
    "revocable",
    "policyDecisionRef",
    "evidenceRefs",
    "capturedAt",
    "status",
}


def verify_receipt(receipt: dict[str, Any], source: str) -> list[str]:
    errors: list[str] = []

    # Required fields
    missing = sorted(REQUIRED_FIELDS - set(receipt))
    if missing:
        errors.append(f"{source}: missing required fields: {', '.join(missing)}")

    if receipt.get("schemaVersion") != SCHEMA_VERSION:
        errors.append(f"{source}: schemaVersion must be '{SCHEMA_VERSION}', got {receipt.get('schemaVersion')!r}")

    receipt_id = receipt.get("receiptId", "")
    if not RECEIPT_ID_PATTERN.match(receipt_id):
        errors.append(
            f"{source}: receiptId must match 'urn:srcos:receipt:browser-automation:<id>', got {receipt_id!r}"
        )

    if not receipt.get("sessionRef"):
        errors.append(f"{source}: sessionRef must be a non-empty string")

    if not receipt.get("ownerRef"):
        errors.append(f"{source}: ownerRef must be a non-empty string (no automation session may run without an owner)")

    transport = receipt.get("transport")
    if transport not in VALID_TRANSPORTS:
        errors.append(f"{source}: transport must be one of {sorted(VALID_TRANSPORTS)}, got {transport!r}")

    scope = receipt.get("permissionScope")
    if not isinstance(scope, list):
        errors.append(f"{source}: permissionScope must be an array")
    else:
        invalid = sorted(set(scope) - VALID_PERMISSIONS)
        if invalid:
            errors.append(f"{source}: unknown permissions: {invalid}")
        if len(scope) != len(set(scope)):
            errors.append(f"{source}: permissionScope must have unique items")

    origin = receipt.get("origin")
    if origin not in VALID_ORIGINS:
        errors.append(f"{source}: origin must be one of {sorted(VALID_ORIGINS)}, got {origin!r}")

    if receipt.get("userVisible") is not True:
        errors.append(f"{source}: userVisible must be true")

    if receipt.get("revocable") is not True:
        errors.append(f"{source}: revocable must be true")

    if not receipt.get("policyDecisionRef"):
        errors.append(f"{source}: policyDecisionRef must be a non-empty string (no automation without a policy decision)")

    if not isinstance(receipt.get("evidenceRefs"), list):
        errors.append(f"{source}: evidenceRefs must be an array")

    if not receipt.get("capturedAt"):
        errors.append(f"{source}: capturedAt must be present")

    status = receipt.get("status")
    if status not in VALID_STATUSES:
        errors.append(f"{source}: status must be one of {sorted(VALID_STATUSES)}, got {status!r}")
    elif status == "revoked" and not receipt.get("revokedAt"):
        errors.append(f"{source}: status=revoked requires revokedAt to be set")

    return errors


def run_builtin_tests() -> int:
    """Run in-process acceptance-criteria test cases and print results."""
    cases: list[tuple[str, dict[str, Any], bool]] = []

    base_good = {
        "schemaVersion": SCHEMA_VERSION,
        "receiptId": "urn:srcos:receipt:browser-automation:test-001",
        "sessionRef": "bb-session-test",
        "ownerRef": "agent-test",
        "transport": "cdp",
        "permissionScope": ["read_dom", "click"],
        "origin": "local",
        "userVisible": True,
        "revocable": True,
        "policyDecisionRef": "policy-decision-test",
        "evidenceRefs": [],
        "capturedAt": "2026-05-06T18:00:00Z",
        "status": "active",
    }

    # 1. Successful local automation
    cases.append(("successful local automation", base_good, True))

    # 2. Denied policy decision
    denied = {**base_good, "status": "denied", "policyDecisionRef": "policy-denied-test"}
    cases.append(("denied policy decision", denied, True))

    # 3. Missing owner
    no_owner = {**base_good, "ownerRef": ""}
    cases.append(("missing owner", no_owner, False))

    # 4. Revoked session (with revokedAt)
    revoked = {**base_good, "status": "revoked", "revokedAt": "2026-05-06T18:30:00Z"}
    cases.append(("revoked session with revokedAt", revoked, True))

    # 5. Revoked session missing revokedAt
    revoked_no_ts = {**base_good, "status": "revoked"}
    cases.append(("revoked session missing revokedAt", revoked_no_ts, False))

    # 6. Orphan event — receipt with status=orphaned, no policyDecisionRef
    orphan = {**base_good, "status": "orphaned", "policyDecisionRef": ""}
    cases.append(("orphan event (no policy decision)", orphan, False))

    passed = 0
    failed = 0
    for name, receipt, expect_valid in cases:
        errs = verify_receipt(receipt, f"test:{name}")
        is_valid = len(errs) == 0
        outcome = "PASS" if is_valid == expect_valid else "FAIL"
        if outcome == "FAIL":
            failed += 1
            print(f"  FAIL  {name}")
            if expect_valid:
                for e in errs:
                    print(f"        {e}")
            else:
                print("        Expected validation errors but got none.")
        else:
            passed += 1
            print(f"  PASS  {name}")

    print(f"\nResults: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify BrowserAutomationReceipt files or run built-in acceptance tests."
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Receipt JSON files to validate. Omit to run built-in acceptance tests.",
    )
    parser.add_argument(
        "--self-test",
        action="store_true",
        help="Run the built-in acceptance-criteria test suite.",
    )
    args = parser.parse_args()

    if args.self_test or not args.files:
        print("BearBrowser BrowserAutomationReceipt acceptance tests")
        print("=" * 55)
        return run_builtin_tests()

    all_errors: list[str] = []
    for file_path in args.files:
        path = Path(file_path).expanduser()
        if not path.exists():
            all_errors.append(f"{path}: file not found")
            continue
        try:
            receipt = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            all_errors.append(f"{path}: invalid JSON: {exc}")
            continue
        if not isinstance(receipt, dict):
            all_errors.append(f"{path}: top-level value must be a JSON object")
            continue
        errors = verify_receipt(receipt, str(path))
        all_errors.extend(errors)
        if not errors:
            print(f"OK: {path}")

    if all_errors:
        for error in all_errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("All receipts valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
