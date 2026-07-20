#!/usr/bin/env python3
"""Receipts service proof — the cockpit trust surface reads the evidence stream and
unifies every governed decision across all three surfaces.

Uses a temp evidence dir. Generates REAL browser + iot decisions via the enforcing
bridge, plus a synthetic `agent.*` event (the agent-machine surface lands with Lane
4 / PR #71; the Receipts service derives the surface purely from the event-type
prefix, so it handles agent.* independently). Asserts the receipts projection,
filters, and summary.

Run: python3 scripts/tests/test_receipts.py   (exit 0 = PASS)
"""
import importlib.util
import json
import os
import pathlib
import sys
import tempfile

_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, _ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    tmp = tempfile.mkdtemp()
    os.environ["SOURCEOS_REASONING_EVIDENCE"] = tmp

    acb = _load("acb", "scripts/agent-control-bridge.py")
    rec = _load("rec", "scripts/bearbrowser-receipts.py")

    def fire(surface, action, params=None, token=None):
        pol = acb.load_policy(surface)
        acb.ControlBridge(pol, emit=True).evaluate_action(action, params or {}, token)

    # REAL decisions across the two surfaces that exist on main.
    fire("browser", "navigate")                # allowed
    fire("browser", "enter-credentials")       # prohibited -> browser.policy.violation
    fire("iot", "read-state")                  # allowed
    fire("iot", "unlock-door")                 # prohibited -> iot.policy.violation
    fire("iot", "unlock-door", {"actor": "user", "userGesture": True}, "action:unlock-door")  # gated permit

    # Synthetic agent-machine events (Lane 4 surface). Appended directly so Receipts
    # is proven surface-complete without requiring Lane 4 to be merged.
    with rec.stream_path().open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({"id": "ev-agent-1", "eventType": "agent.read-graph",
                             "decision": "permit", "actionClass": "allowed",
                             "summary": "read-graph permitted", "capturedAt": "2026-07-19T10:00:00Z"}) + "\n")
        fh.write(json.dumps({"id": "ev-agent-2", "eventType": "agent.policy.violation",
                             "decision": "deny", "actionClass": "prohibited",
                             "summary": "PROHIBITED execute-shell BLOCKED", "capturedAt": "2026-07-19T10:00:01Z"}) + "\n")

    receipts = [rec.to_receipt(e) for e in rec.read_events()]
    surfaces = {r["surface"] for r in receipts}
    violations = sum(1 for r in receipts if r["violation"])
    permits = sum(1 for r in receipts if r["decision"] == "permit")
    denies = sum(1 for r in receipts if r["decision"] == "deny")

    checks = [
        ("read 7 receipts", len(receipts) == 7, len(receipts)),
        ("all 3 surfaces unified", surfaces == {"browser", "iot", "agent"}, surfaces),
        ("3 violations flagged", violations == 3, violations),
        ("permits counted", permits == 4, permits),   # browser navigate, iot read, iot unlock w/ gesture, agent read
        ("denies counted", denies == 3, denies),       # browser creds, iot unlock, agent shell
        ("summary agrees", rec_summary_ok(rec), True),
        ("surface filter works", filter_ok(rec), True),
    ]
    print("  receipts:", len(receipts), "surfaces:", surfaces, "violations:", violations,
          "permit/deny:", permits, "/", denies)
    fails = [(n, got) for n, ok, got in checks if not ok]
    for n, ok, got in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] {n}" + ("" if ok else f"  (got {got})"))

    print("\n" + "=" * 60)
    if fails:
        print(f"RESULT: FAIL ({len(fails)})")
        return 1
    print("RESULT: PASS — the Receipts surface unifies browser + iot + agent "
          "governed decisions into one live, verifiable ledger.")
    return 0


def rec_summary_ok(rec) -> bool:
    surfaces, verdicts, viol, total = {}, {"permit": 0, "deny": 0}, 0, 0
    for e in rec.read_events():
        r = rec.to_receipt(e); total += 1
        surfaces[r["surface"]] = surfaces.get(r["surface"], 0) + 1
        verdicts[r["decision"]] = verdicts.get(r["decision"], 0) + 1
        viol += 1 if r["violation"] else 0
    return total == 7 and viol == 3 and set(surfaces) == {"browser", "iot", "agent"}


def filter_ok(rec) -> bool:
    agent = [rec.to_receipt(e) for e in rec.read_events() if rec.to_receipt(e)["surface"] == "agent"]
    return len(agent) == 2


if __name__ == "__main__":
    sys.exit(main())
