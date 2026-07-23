#!/usr/bin/env python3
"""Capture-surface injection-containment proof — the network-visibility twin of
test_iot_injection_containment.py.

The capture-sidecar exposes session packet capture, a live connection map, and a
per-domain firewall. The SAME enforcing bridge (agent-control-bridge.py) governs
it, via spec.captureActionContract (surface="capture"). Packet capture and pcap
export are the two EXFILTRATION vectors on this surface. This test proves,
WITHOUT any live capture engine, that:

  * read-only surfaces (status, connection list, firewall list) are permitted and
    attest capture.<action> events;
  * stopping a capture and setting a firewall rule are gated (denied without a
    per-action token, permitted with one);
  * starting a whole-session packet capture and EXPORTING the pcap are PROHIBITED
    — an agent/injected request is BLOCKED at decision time and attests a
    capture.policy.violation, never merely logged after;
  * capture/export are reclassified to gated ONLY on an explicit cockpit user
    gesture (actor==user AND userGesture==true) — an agent cannot forge it;
  * a permitted (post-gesture) capture attests capture.capture-start, NOT a
    violation;
  * an agent that FORGES userGesture but is not the user stays prohibited.

Run: python3 scripts/tests/test_capture_injection_containment.py   (exit 0 = PASS)
"""
import importlib.util
import pathlib
import sys

_ROOT = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "acb", _ROOT / "scripts" / "agent-control-bridge.py")
acb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acb)


def _eval(policy, action, params=None, token=None):
    bridge = acb.ControlBridge(policy, emit=False)
    return bridge.evaluate_action(action, params or {}, token)


# (name, action, params, token, expect_decision, expect_class, expect_event)
CASES = [
    # Read-only surfaces are always allowed.
    ("allowed: status",               "capture-status",   {},                                       None,                    "permit", "allowed",    "capture.capture-status"),
    ("allowed: list-connections",     "list-connections", {},                                       None,                    "permit", "allowed",    "capture.list-connections"),
    ("allowed: list-firewall",        "list-firewall",    {},                                       None,                    "permit", "allowed",    "capture.list-firewall"),
    # Reversible effects are gated: denied without a token, permitted with one.
    ("gated: capture-stop no tok",    "capture-stop",     {},                                       None,                    "deny",   "gated",      "capture.capture-stop"),
    ("gated: capture-stop w/ tok",    "capture-stop",     {},                                       "action:capture-stop",   "permit", "gated",      "capture.capture-stop"),
    ("gated: firewall-set no tok",    "firewall-set",     {"domain": "ads.example", "decision": "block"}, None,               "deny",   "gated",      "capture.firewall-set"),
    ("gated: firewall-set w/ tok",    "firewall-set",     {"domain": "ads.example", "decision": "block"}, "action:firewall-set", "permit", "gated",  "capture.firewall-set"),
    # THE CONTAINMENT BAR: an injected/agent capture or export is blocked outright.
    ("INJECTED agent capture-start",  "capture-start",    {},                                       None,                    "deny",   "prohibited", "capture.policy.violation"),
    ("INJECTED agent capture-export", "capture-export",   {},                                       None,                    "deny",   "prohibited", "capture.policy.violation"),
    ("INJECTED start w/ stolen tok",  "capture-start",    {},                                       "action:capture-start",  "deny",   "prohibited", "capture.policy.violation"),
    # An agent that FORGES the gesture but is not the user stays prohibited.
    ("forged gesture wrong actor",    "capture-start",    {"actor": "agent", "userGesture": True},  "action:capture-start",  "deny",   "prohibited", "capture.policy.violation"),
    # userGesture without actor==user: prohibited.
    ("gesture without user actor",    "capture-start",    {"userGesture": True},                    "action:capture-start",  "deny",   "prohibited", "capture.policy.violation"),
    # Only an explicit cockpit user gesture reclassifies to gated; then it still
    # needs a per-action token. Post-gesture permit attests the natural event.
    ("user-gesture start no tok",     "capture-start",    {"actor": "user", "userGesture": True},   None,                    "deny",   "gated",      "capture.capture-start"),
    ("user-gesture start w/ tok",     "capture-start",    {"actor": "user", "userGesture": True},   "action:capture-start",  "permit", "gated",      "capture.capture-start"),
    ("user-gesture export w/ tok",    "capture-export",   {"actor": "user", "userGesture": True},   "action:capture-export", "permit", "gated",      "capture.capture-export"),
    # Unknown action fails closed (prohibited).
    ("unknown action fails closed",   "sniff-all",        {},                                       None,                    "deny",   "prohibited", "capture.policy.violation"),
]


def main() -> int:
    policy = acb.load_policy("capture")
    failures = []
    for name, action, params, token, exp_dec, exp_cls, exp_ev in CASES:
        d = _eval(policy, action, params, token)
        got_ev = d.event["eventType"]
        ok = (d.decision == exp_dec and d.action_class == exp_cls and got_ev == exp_ev)
        # No capture event may ever carry another surface's prefix (isolation).
        if got_ev.startswith("browser.") or got_ev.startswith("iot.") or got_ev.startswith("agent."):
            ok = False
        mark = "PASS" if ok else "FAIL"
        if not ok:
            failures.append(
                f"{name}: got ({d.decision},{d.action_class},{got_ev}) "
                f"expected ({exp_dec},{exp_cls},{exp_ev})")
        print(f"  [{mark}] {name:34s} -> {d.decision:6s} {d.action_class:10s} {got_ev}")

    print("\n" + "=" * 70)
    total = len(CASES)
    print(f"PASSED {total - len(failures)}   FAILED {len(failures)}")
    if failures:
        print("\nFAILURES:")
        for f in failures:
            print("  " + f)
        print("\nRESULT: FAIL")
        return 1
    print("\nRESULT: PASS — injected/agent packet capture + pcap export BLOCKED at "
          "decision time + attested.\nContainment proven without a live capture engine "
          "(enforce-only mode).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
