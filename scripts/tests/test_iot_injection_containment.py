#!/usr/bin/env python3
"""IoT injection-containment proof — the physical-world twin of
test_injection_containment.py.

The BearBrowser cockpit is the sovereign control plane for the user's smart-home
estate. The SAME enforcing bridge (agent-control-bridge.py) that governs browser
actions governs physical ones, via spec.iotActionContract (surface="iot"). This
test proves, WITHOUT any live device, that:

  * read-only queries are permitted and attest iot.<action> events;
  * reversible physical effects are gated (denied without a per-action token,
    permitted with one);
  * security-critical actions (unlock-door, disarm-security, open-garage-door,
    disable-camera/sensor, pair-device, add-user, factory-reset, firmware-update)
    are PROHIBITED — an agent/injected request is BLOCKED at decision time and
    attests an iot.policy.violation, never merely logged after;
  * a prohibited action is reclassified to gated ONLY on an explicit cockpit user
    gesture (actor==user AND userGesture==true) — an agent cannot forge it;
  * a permitted (post-gesture) unlock attests iot.unlock-door, NOT a violation;
  * a scene/routine that bundles a prohibited action inherits prohibited.

Run: python3 scripts/tests/test_iot_injection_containment.py   (exit 0 = PASS)
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
    ("allowed: list-devices",        "list-devices",   {},                                    None,                 "permit", "allowed",    "iot.list-devices"),
    ("allowed: read-state",          "read-state",     {},                                    None,                 "permit", "allowed",    "iot.read-state"),
    ("gated: set-brightness no tok",  "set-brightness", {},                                    None,                 "deny",   "gated",      "iot.set-brightness"),
    ("gated: set-brightness w/ tok",  "set-brightness", {},                                    "action:set-brightness", "permit", "gated",   "iot.set-brightness"),
    ("gated: set-thermostat no tok",  "set-thermostat", {},                                    None,                 "deny",   "gated",      "iot.set-thermostat"),
    ("gated: lock-door (safe) no tok","lock-door",      {},                                    None,                 "deny",   "gated",      "iot.lock-door"),
    # THE CONTAINMENT BAR: injected/agent physical actions are blocked outright.
    ("INJECTED agent unlock-door",    "unlock-door",    {},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
    ("INJECTED disarm-security",      "disarm-security",{},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
    ("INJECTED open-garage-door",     "open-garage-door",{},                                   None,                 "deny",   "prohibited", "iot.policy.violation"),
    ("INJECTED disable-camera",       "disable-camera", {},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
    ("INJECTED factory-reset",        "factory-reset",  {},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
    ("INJECTED pair-device",          "pair-device",    {},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
    ("INJECTED add-user",             "add-user",       {},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
    # A user gesture reclassifies unlock DOWN to gated — still needs a token.
    ("user-gesture unlock no tok",    "unlock-door",    {"actor": "user", "userGesture": True}, None,                "deny",   "gated",      "iot.unlock-door"),
    # ...and with the token it PERMITS — and attests iot.unlock-door, not a violation.
    ("user-gesture unlock w/ tok",    "unlock-door",    {"actor": "user", "userGesture": True}, "action:unlock-door","permit", "gated",     "iot.unlock-door"),
    # An agent that FORGES userGesture but is not the user stays prohibited.
    ("forged gesture wrong actor",    "unlock-door",    {"actor": "agent", "userGesture": True},"action:unlock-door","deny",   "prohibited", "iot.policy.violation"),
    # userGesture without actor==user: prohibited.
    ("gesture without user actor",    "unlock-door",    {"userGesture": True},                 "action:unlock-door", "deny",   "prohibited", "iot.policy.violation"),
    # A scene/routine that bundles a prohibited action inherits prohibited.
    ("scene bundles unlock",          "set-scene",      {"includesAction": "unlock-door"},     "action:set-scene",   "deny",   "prohibited", "iot.policy.violation"),
    # A benign scene is gated as normal.
    ("benign scene w/ tok",           "set-scene",      {"includesAction": "set-brightness"},  "action:set-scene",   "permit", "gated",      "iot.set-scene"),
    # Unknown action fails closed (prohibited).
    ("unknown action fails closed",   "reprogram-hub",  {},                                    None,                 "deny",   "prohibited", "iot.policy.violation"),
]


def main() -> int:
    policy = acb.load_policy("iot")
    failures = []
    for name, action, params, token, exp_dec, exp_cls, exp_ev in CASES:
        d = _eval(policy, action, params, token)
        got_ev = d.event["eventType"]
        ok = (d.decision == exp_dec and d.action_class == exp_cls and got_ev == exp_ev)
        # No IoT event may ever carry the browser prefix (surface isolation).
        if got_ev.startswith("browser."):
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
        print("\nRESULT: FAIL — IoT containment NOT proven")
        for f in failures:
            print("  - " + f)
        return 1
    print("\nRESULT: PASS — rogue/injected PHYSICAL actions BLOCKED at decision "
          "time + attested.\nContainment proven without a live device (enforce-only mode).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
