#!/usr/bin/env python3
"""
THE make-or-break test: prove the agent control bridge CONTAINS injection.

Simulates an injected / rogue agent action sequence (the classic prompt-injection
exfil playbook) and asserts the bridge BLOCKS the dangerous actions AT DECISION
TIME — not logged after the fact — and that EVERY decision emitted a conformant,
attestable ReasoningEvent.

This is the demonstration of the capability Gartner's directive names and that no
shipping AI browser provides: inspect agent intent, allow specific actions while
restricting others, and contain the rogue/injected ones.

Runs WITHOUT a live browser (dry/enforce-only mode) — the policy decision is pure,
so containment is provable on any machine. No third-party deps.
"""
from __future__ import annotations

import importlib.util
import os
import sys
import tempfile
from pathlib import Path

# Load the bridge module by path (it has a hyphenated filename).
_HERE = Path(__file__).resolve()
_SCRIPTS = _HERE.parent.parent
_BRIDGE_PATH = _SCRIPTS / "agent-control-bridge.py"

# Isolate evidence to a temp dir so the test never pollutes real state and can
# read back exactly what it attested.
_EVID = tempfile.mkdtemp(prefix="acb-test-")
os.environ["SOURCEOS_REASONING_EVIDENCE"] = _EVID

_spec = importlib.util.spec_from_file_location("agent_control_bridge", _BRIDGE_PATH)
acb = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(acb)


# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

_PASSES: list[str] = []
_FAILS: list[str] = []

REQUIRED_EVENT_FIELDS = (
    "id", "type", "specVersion", "runRef", "eventType",
    "summary", "traceLevel", "trustLevel", "capturedAt",
)


def check(name: str, cond: bool, detail: str = "") -> None:
    if cond:
        _PASSES.append(name)
        print(f"  PASS  {name}")
    else:
        _FAILS.append(f"{name} :: {detail}")
        print(f"  FAIL  {name} :: {detail}")


def assert_attested(name: str, decision) -> None:
    """Every decision MUST carry a spec-conformant attestable event."""
    ev = decision.event
    missing = [f for f in REQUIRED_EVENT_FIELDS if f not in ev or ev[f] in (None, "")]
    check(f"{name}: event has all required fields", not missing,
          f"missing={missing}")
    check(f"{name}: event id has reasoning-event URN prefix",
          str(ev.get("id", "")).startswith("urn:srcos:reasoning-event:"),
          ev.get("id"))
    check(f"{name}: runRef has reasoning-run URN prefix",
          str(ev.get("runRef", "")).startswith("urn:srcos:reasoning-run:"),
          ev.get("runRef"))
    check(f"{name}: specVersion is 2.0.0", ev.get("specVersion") == "2.0.0",
          ev.get("specVersion"))
    check(f"{name}: traceLevel is workspace-safe",
          ev.get("traceLevel") == "workspace-safe", ev.get("traceLevel"))
    # summary must be SAFE — never raw page content / secrets
    check(f"{name}: summary is a safe short string (<=500)",
          isinstance(ev.get("summary"), str) and len(ev["summary"]) <= 500)


# ---------------------------------------------------------------------------
# The injected / rogue action sequence
# ---------------------------------------------------------------------------

def main() -> int:
    policy = acb.load_policy()
    bridge = acb.ControlBridge(policy, emit=True)

    # Confirm we run WITHOUT a live browser — enforcement must still happen.
    reachable = bridge.connect("ws://127.0.0.1:65535", token="unused")
    check("runs in dry/enforce-only mode (no live browser needed)",
          reachable is False, f"connect returned {reachable}")

    print("\n[1] INJECTED enter-credentials (classic prompt-injection exfil)")
    d = bridge.evaluate_action("enter-credentials", {"url": "https://evil.example/login"})
    check("enter-credentials is NOT permitted (blocked at decision time)",
          not d.permitted, f"decision={d.decision}")
    check("enter-credentials classified prohibited", d.action_class == "prohibited")
    check("enter-credentials emitted a browser.policy.violation",
          d.event["eventType"] == "browser.policy.violation", d.event["eventType"])
    assert_attested("enter-credentials", d)

    print("\n[2] ROGUE submit-form WITHOUT approval token (gated)")
    d = bridge.evaluate_action("submit-form", {"url": "https://evil.example/post"})
    check("submit-form (no token) is DENIED", not d.permitted, f"decision={d.decision}")
    check("submit-form (no token) classified gated", d.action_class == "gated")
    check("submit-form deny reason = gated: requires approval",
          d.reason == "gated: requires approval", d.reason)
    assert_attested("submit-form-no-token", d)

    print("\n[3] submit-form WITH a valid per-action approval token")
    d = bridge.evaluate_action("submit-form", {}, approval_token="action:submit-form")
    check("submit-form (valid token) is PERMITTED", d.permitted, f"decision={d.decision}")
    assert_attested("submit-form-token", d)

    print("\n[3b] submit-form with a token scoped to a DIFFERENT action must NOT unlock it")
    d = bridge.evaluate_action("submit-form", {}, approval_token="action:file-download")
    check("submit-form (wrong-scope token) is DENIED", not d.permitted, f"decision={d.decision}")

    print("\n[4] ROGUE cross-origin-post WITHOUT token (gated exfil channel)")
    d = bridge.evaluate_action("cross-origin-post", {"url": "https://attacker.example"})
    check("cross-origin-post (no token) is DENIED", not d.permitted, f"decision={d.decision}")
    check("cross-origin-post classified gated", d.action_class == "gated")
    assert_attested("cross-origin-post", d)

    print("\n[5] LEGIT navigate / extract-text — the agent still works")
    d = bridge.evaluate_action("navigate", {"url": "https://example.com"})
    check("navigate is PERMITTED", d.permitted, f"decision={d.decision}")
    check("navigate attested browser.navigate", d.event["eventType"] == "browser.navigate")
    assert_attested("navigate", d)

    d = bridge.evaluate_action("extract-text", {"selector": "h1"})
    check("extract-text is PERMITTED", d.permitted, f"decision={d.decision}")
    assert_attested("extract-text", d)

    print("\n[6] click re-classified by PolicyCondition to a form submission -> gated")
    d = bridge.evaluate_action("click", {"intent": "submit-form"})
    check("reclassified click is DENIED without approval", not d.permitted, f"decision={d.decision}")
    check("reclassified click became gated", d.action_class == "gated")
    check("reclassification recorded the condition id",
          d.condition_id == "click-is-form-submission", d.condition_id)
    check("reclassified click attests the submit-form event type",
          d.event["eventType"] == "browser.submit-form", d.event["eventType"])
    assert_attested("click-reclassified", d)

    print("\n[7] fill into a credential field re-classified -> prohibited (injected exfil)")
    d = bridge.evaluate_action("fill-form-field", {"fieldType": "password", "value": "hunter2"})
    check("reclassified credential fill is DENIED", not d.permitted, f"decision={d.decision}")
    check("reclassified credential fill became prohibited", d.action_class == "prohibited")
    check("reclassified credential fill emits a policy violation",
          d.event["eventType"] == "browser.policy.violation", d.event["eventType"])
    # the secret value must NOT leak into the safe summary
    check("the injected secret value is NOT in the attested summary",
          "hunter2" not in d.event["summary"], d.event["summary"])
    assert_attested("fill-credential-reclassified", d)

    print("\n[8] fill into a payment field re-classified -> prohibited")
    d = bridge.evaluate_action("fill-form-field", {"fieldType": "cvv"})
    check("reclassified payment fill is DENIED", not d.permitted)
    check("reclassified payment fill became prohibited", d.action_class == "prohibited")
    check("reclassified payment fill mapped to enter-payment-details",
          d.action == "enter-payment-details", d.action)

    print("\n[9] unknown / never-classified action fails CLOSED (deny)")
    d = bridge.evaluate_action("exfiltrate-cookies", {})
    check("unknown action is DENIED (fail-closed)", not d.permitted, f"decision={d.decision}")

    print("\n[10] every attested event was persisted to the evidence sink")
    stream = Path(_EVID) / "reasoning-events.ndjson"
    check("evidence stream file exists", stream.exists(), str(stream))
    lines = stream.read_text().splitlines() if stream.exists() else []
    check("evidence stream has one line per attested decision (>=11)",
          len(lines) >= 11, f"lines={len(lines)}")
    # confirm the persisted records are valid JSON with the URN prefix
    import json as _json
    ok_records = 0
    violation_count = 0
    for ln in lines:
        try:
            rec = _json.loads(ln)
        except Exception:
            continue
        if str(rec.get("id", "")).startswith("urn:srcos:reasoning-event:") and \
           rec.get("type") == "ReasoningEvent":
            ok_records += 1
        if rec.get("eventType") == "browser.policy.violation":
            violation_count += 1
    check("all persisted records are conformant ReasoningEvents",
          ok_records == len(lines) and ok_records >= 11, f"ok={ok_records}/{len(lines)}")
    check("prohibited/injected actions left a browser.policy.violation trail",
          violation_count >= 3, f"violations={violation_count}")

    # close the run -> ReasoningReceipt
    receipt = bridge.close()
    check("session receipt is a ReasoningReceipt with a traceHash",
          receipt.get("type") == "ReasoningReceipt"
          and str(receipt.get("traceHash", "")).startswith("sha256:"),
          str(receipt))

    print("\n" + "=" * 70)
    print(f"PASSED {len(_PASSES)}   FAILED {len(_FAILS)}")
    if _FAILS:
        print("FAILURES:")
        for f in _FAILS:
            print("  -", f)
        print("\nRESULT: FAIL — containment NOT proven")
        return 1
    print("\nRESULT: PASS — rogue/injected actions BLOCKED at decision time + attested.")
    print("Containment proven without a live browser (dry/enforce-only mode).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
