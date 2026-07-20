#!/usr/bin/env python3
"""Agent-machine injection-containment proof — Lane 4 of the cockpit composition.

The cockpit's local agent (bundled Noetica agent-machine) is governed by the SAME
enforcing bridge as the browser and the IoT estate, via spec.agentMachineActionContract
(surface="agent-machine"), fronted by scripts/bearbrowser-agent-machine-gate.py.
This proves, WITHOUT running the sidecar, that:

  * read-only agent surfaces (graph/knowledge/status/models) are permitted + attest
    agent.<action> events;
  * mutating/executing actions (run-pipeline, write-knowledge, mutate-graph,
    devspace-command, install-package, network-fetch) are gated — denied without a
    per-action approval token, permitted with one;
  * host-reaching / destructive actions (execute-shell, read/write-host-filesystem,
    read-credentials, disable-egress-guard, disable-governance) are PROHIBITED — an
    agent/prompt-injected request is BLOCKED at decision time and attests an
    agent.policy.violation, never merely logged after;
  * a prohibited action is reclassified to gated ONLY on an explicit cockpit user
    gesture (actor==user AND userGesture==true) — the agent planner cannot forge it;
  * the gate's route→action mapping classifies unknown mutating routes to a
    prohibited action (fail-closed), and never lets an unmapped POST through.

Run: python3 scripts/tests/test_agent_machine_containment.py   (exit 0 = PASS)
"""
import importlib.util
import pathlib
import sys

_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _load(name, rel):
    spec = importlib.util.spec_from_file_location(name, _ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


acb = _load("acb", "scripts/agent-control-bridge.py")
gate = _load("amgate", "scripts/bearbrowser-agent-machine-gate.py")


def _eval(policy, action, params=None, token=None):
    b = acb.ControlBridge(policy, emit=False)
    return b.evaluate_action(action, params or {}, token)


# ── Part 1: the governance surface (agentMachineActionContract) ──────────────────
# (name, action, params, token, expect_decision, expect_class, expect_event)
SURFACE_CASES = [
    ("allowed: read-graph",        "read-graph",     {},                                    None,                    "permit", "allowed",    "agent.read-graph"),
    ("allowed: query-status",      "query-status",   {},                                    None,                    "permit", "allowed",    "agent.query-status"),
    ("allowed: chat-completion",   "chat-completion",{},                                    None,                    "permit", "allowed",    "agent.chat-completion"),
    ("gated: run-pipeline no tok", "run-pipeline",   {},                                    None,                    "deny",   "gated",      "agent.run-pipeline"),
    ("gated: run-pipeline w/ tok", "run-pipeline",   {},                                    "action:run-pipeline",   "permit", "gated",      "agent.run-pipeline"),
    ("gated: write-knowledge",     "write-knowledge",{},                                    None,                    "deny",   "gated",      "agent.write-knowledge"),
    ("gated: devspace no tok",     "devspace-command",{},                                   None,                    "deny",   "gated",      "agent.devspace-command"),
    # THE CONTAINMENT BAR: injected/agent host-reaching actions blocked outright.
    ("INJECTED execute-shell",     "execute-shell",  {},                                    None,                    "deny",   "prohibited", "agent.policy.violation"),
    ("INJECTED read-credentials",  "read-credentials",{},                                   None,                    "deny",   "prohibited", "agent.policy.violation"),
    ("INJECTED disable-egress",    "disable-egress-guard",{},                               None,                    "deny",   "prohibited", "agent.policy.violation"),
    ("INJECTED disable-governance","disable-governance",{},                                 None,                    "deny",   "prohibited", "agent.policy.violation"),
    ("INJECTED write-host-fs",     "write-host-filesystem",{},                              None,                    "deny",   "prohibited", "agent.policy.violation"),
    # user gesture reclassifies shell DOWN to gated — still needs a token.
    ("user-gesture shell no tok",  "execute-shell",  {"actor": "user", "userGesture": True}, None,                   "deny",   "gated",      "agent.execute-shell"),
    ("user-gesture shell w/ tok",  "execute-shell",  {"actor": "user", "userGesture": True}, "action:execute-shell","permit", "gated",     "agent.execute-shell"),
    # an agent forging userGesture but not actor==user stays prohibited.
    ("forged gesture wrong actor", "execute-shell",  {"actor": "agent", "userGesture": True},"action:execute-shell","deny",   "prohibited", "agent.policy.violation"),
    # unknown action fails closed.
    ("unknown action fails closed","reprogram-brain",{},                                    None,                    "deny",   "prohibited", "agent.policy.violation"),
]

# ── Part 2: the gate's route → action classification ────────────────────────────
# (name, method, path, expected_action)
ROUTE_CASES = [
    ("GET status",           "GET",  "/api/status",              "query-status"),
    ("GET graph read",       "GET",  "/api/graph/nodes",         "read-graph"),
    ("POST chat",            "POST", "/api/chat/completions",    "chat-completion"),
    ("POST pipeline run",    "POST", "/api/pipeline/run",        "run-pipeline"),
    ("POST devspace exec",   "POST", "/api/devspace/exec",       "execute-shell"),  # /exec wins (prohibited) — good
    ("POST knowledge write", "POST", "/api/knowledge/upsert",    "write-knowledge"),
    ("POST graph mutate",    "POST", "/api/graph/edge",          "mutate-graph"),
    ("POST shell",           "POST", "/api/shell",               "execute-shell"),
    ("POST fs write",        "POST", "/api/fs/write",            "write-host-filesystem"),
    ("POST credentials",     "POST", "/api/credential/get",      "read-credentials"),
    ("POST unknown mutation","POST", "/api/some/new/thing",      "execute-shell"),  # fail-closed
    ("GET unknown",          "GET",  "/api/some/new/thing",      "query-status"),
]


def main() -> int:
    policy = acb.load_policy("agent-machine")
    failures = []

    for name, action, params, token, exp_dec, exp_cls, exp_ev in SURFACE_CASES:
        d = _eval(policy, action, params, token)
        got_ev = d.event["eventType"]
        ok = (d.decision == exp_dec and d.action_class == exp_cls and got_ev == exp_ev
              and not got_ev.startswith(("browser.", "iot.")))
        if not ok:
            failures.append(f"[surface] {name}: got ({d.decision},{d.action_class},{got_ev}) "
                            f"expected ({exp_dec},{exp_cls},{exp_ev})")
        print(f"  [{'PASS' if ok else 'FAIL'}] surface: {name:32s} -> {d.decision:6s} {d.action_class:10s} {got_ev}")

    for name, method, path, exp_action in ROUTE_CASES:
        got = gate.classify_action(method, path)
        ok = got == exp_action
        if not ok:
            failures.append(f"[route] {name}: {method} {path} -> {got} (expected {exp_action})")
        print(f"  [{'PASS' if ok else 'FAIL'}] route:   {name:32s} -> {got}")

    total = len(SURFACE_CASES) + len(ROUTE_CASES)
    print("\n" + "=" * 70)
    print(f"PASSED {total - len(failures)}   FAILED {len(failures)}")
    if failures:
        print("\nRESULT: FAIL — agent-machine containment NOT proven")
        for f in failures:
            print("  - " + f)
        return 1
    print("\nRESULT: PASS — rogue/injected COCKPIT-AGENT actions BLOCKED at decision "
          "time + attested.\nThe local agent is governed by the same engine as the "
          "browser and the IoT estate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
