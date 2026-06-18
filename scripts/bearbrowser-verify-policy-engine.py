#!/usr/bin/env python3
"""
BearBrowser policy engine verifier.

Runs the policy engine for every known action type in dry-run mode and verifies:
  - Required fields are present in the JSON output
  - Exit code 0 for allow/observe decisions
  - Exit code 2 for hold decisions
  - Exit code 3 for deny decisions

Run standalone:
  python3 bearbrowser-verify-policy-engine.py
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Test cases: (action, profile, expected_decision, expected_exit_code)
# ---------------------------------------------------------------------------

REQUIRED_FIELDS = {
    "decisionId",
    "action",
    "profile",
    "decision",
    "risk",
    "requiresUserApproval",
    "reason",
    "timestamp",
    "engine",
    "product",
    "schemaVersion",
    "context",
}

# Map of decision -> expected exit code
DECISION_EXIT_CODES = {
    "allow": 0,
    "observe": 0,
    "hold": 2,
    "deny": 3,
}

# All known actions with their expected decisions per profile
# (action, profile, expected_decision)
TEST_CASES: list[tuple[str, str, str]] = [
    # human-secure profile (default)
    ("navigate",              "human-secure",  "allow"),
    ("summarize_page",        "human-secure",  "observe"),
    ("compare_tabs",          "human-secure",  "hold"),
    ("share_page_with_agent", "human-secure",  "hold"),
    ("request_credential",    "human-secure",  "hold"),
    ("request_autofill",      "human-secure",  "hold"),
    ("download_file",         "human-secure",  "hold"),
    ("upload_file",           "human-secure",  "hold"),
    ("read_clipboard",        "human-secure",  "hold"),
    ("write_clipboard",       "human-secure",  "hold"),
    ("run_automation",        "human-secure",  "hold"),
    ("write_memory_candidate","human-secure",  "hold"),
    ("commit_memory",         "human-secure",  "hold"),
    # agent-runtime profile overrides
    ("navigate",              "agent-runtime", "hold"),
    ("request_credential",    "agent-runtime", "deny"),
    ("request_autofill",      "agent-runtime", "deny"),
    ("upload_file",           "agent-runtime", "hold"),
    ("run_automation",        "agent-runtime", "hold"),
    # non-overridden actions fall through to base defaults in agent-runtime
    ("summarize_page",        "agent-runtime", "observe"),
    ("download_file",         "agent-runtime", "hold"),
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SCRIPT = Path(__file__).resolve().parent / "bearbrowser-policy-engine.py"


def run_engine(action: str, profile: str) -> tuple[int, dict[str, Any] | None, str]:
    """
    Run the policy engine in dry-run mode.
    Returns (exit_code, parsed_json_or_None, raw_stdout).
    """
    result = subprocess.run(
        [sys.executable, str(SCRIPT),
         "--action", action,
         "--profile", profile,
         "--context", "sessionId=verify-test", "tabId=0",
         "--dry-run"],
        capture_output=True,
        text=True,
    )
    raw = result.stdout.strip()
    parsed = None
    try:
        parsed = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        pass
    return result.returncode, parsed, raw


def check_required_fields(record: dict[str, Any]) -> list[str]:
    missing = []
    for field in sorted(REQUIRED_FIELDS):
        if field not in record:
            missing.append(field)
    return missing


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    if not SCRIPT.exists():
        print(f"ERROR: Policy engine not found at {SCRIPT}", file=sys.stderr)
        return 1

    pass_count = 0
    fail_count = 0
    results: list[tuple[str, bool, str]] = []

    print(f"BearBrowser policy engine verifier")
    print(f"Engine: {SCRIPT}")
    print(f"Tests:  {len(TEST_CASES)}")
    print()

    for action, profile, expected_decision in TEST_CASES:
        label = f"{action} [{profile}]"
        exit_code, record, raw = run_engine(action, profile)
        expected_code = DECISION_EXIT_CODES.get(expected_decision, 0)

        errors: list[str] = []

        # 1. Parse check
        if record is None:
            errors.append(f"JSON parse failed. Raw output: {raw[:200]!r}")
        else:
            # 2. Required fields
            missing = check_required_fields(record)
            if missing:
                errors.append(f"Missing fields: {', '.join(missing)}")

            # 3. Decision value
            got_decision = record.get("decision")
            if got_decision != expected_decision:
                errors.append(f"decision={got_decision!r}, expected={expected_decision!r}")

            # 4. Dry-run flag present
            if not record.get("dryRun"):
                errors.append("dryRun field missing or false in dry-run output")

            # 5. Schema version
            if record.get("schemaVersion") != "bearbrowser.policy_decision.v1":
                errors.append(f"schemaVersion={record.get('schemaVersion')!r}")

            # 6. Action echo
            if record.get("action") != action:
                errors.append(f"action field={record.get('action')!r}, expected={action!r}")

            # 7. Profile echo
            if record.get("profile") != profile:
                errors.append(f"profile field={record.get('profile')!r}, expected={profile!r}")

        # 8. Exit code
        if exit_code != expected_code:
            errors.append(f"exit code={exit_code}, expected={expected_code}")

        passed = len(errors) == 0
        if passed:
            pass_count += 1
            results.append((label, True, ""))
        else:
            fail_count += 1
            results.append((label, False, "; ".join(errors)))

    # --- Report ---
    width = max(len(r[0]) for r in results) + 2
    for label, passed, detail in results:
        status = "PASS" if passed else "FAIL"
        line = f"  [{status}] {label:<{width}}"
        if not passed:
            line += f"  {detail}"
        print(line)

    print()

    # --- Additional: invalid action test ---
    print("  Checking unknown action → exit code 1 ...")
    res = subprocess.run(
        [sys.executable, str(SCRIPT), "--action", "totally_bogus_action",
         "--profile", "human-secure", "--dry-run"],
        capture_output=True, text=True,
    )
    if res.returncode == 1:
        print("  [PASS] Unknown action exits with code 1")
        pass_count += 1
    else:
        print(f"  [FAIL] Unknown action returned exit code {res.returncode}, expected 1")
        fail_count += 1

    # --- Summary ---
    total = pass_count + fail_count
    print()
    print(f"Results: {pass_count}/{total} passed, {fail_count} failed")

    return 0 if fail_count == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
