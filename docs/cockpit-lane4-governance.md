# Cockpit Lane 4 — governing the local agent

Lane 4 of `docs/cockpit-composition-plan.md`. Puts BearBrowser's enforcing policy
engine in front of the cockpit's local agent (the bundled Noetica agent-machine
loopback sidecar), so **the same engine that governs the browser and the IoT estate
governs the cockpit agent** — the Gartner "inspect agent intent + enforce per-action
policy" control, applied to our own agent. A prompt-injected `execute-shell` is
denied at decision time and attested, never merely logged after.

## What this adds (all in-repo, no edits to the Noetica engine)
- **`spec.agentMachineActionContract`** in `policy/bearbrowser-contract.yaml` — the
  action→class map for the local agent: allowed (read-only), gated (mutating/
  executing, needs a per-action approval token), prohibited (host-reaching /
  destructive; denied unless a cockpit user gesture proves `actor==user &&
  userGesture==true`, unforgeable by the agent planner).
- **`agent-control-bridge.py --surface agent-machine`** — one more namespace on the
  same enforcing bridge; emits `agent.<action>` / `agent.policy.violation` events.
- **`scripts/bearbrowser-agent-machine-gate.py`** — a loopback governance proxy:
  the cockpit talks to the gate, the gate classifies every request through the
  bridge (`allowed`→forward, `gated`→forward only with a valid token, `prohibited`→
  403 + attest), then forwards permitted requests to the real sidecar. Unrecognized
  mutating routes fail closed.
- **`scripts/tests/test_agent_machine_containment.py`** — 28/28: the governance
  surface + the gate's route→action mapping. (Browser 79/79 and IoT 20/20 unchanged.)

## Data flow
```
cockpit (client-vue) ─► am-gate 127.0.0.1:8080 ─► [classify via bridge] ─► agent-machine 127.0.0.1:8091
                                                        prohibited → 403 + agent.policy.violation
```
The cockpit UI sets, on DIRECT user interaction only, headers the agent cannot forge:
`X-Cockpit-Actor: user`, `X-Cockpit-User-Gesture: true`, and for gated actions
`X-Cockpit-Approval-Token: action:<name>`.

## Integration with Lane 3 (one change, when both land)
Lane 3's `scripts/bearbrowser-agent-machine` launcher currently starts the sidecar on
the cockpit-facing port (default 8080). To insert the gate, start the sidecar on the
**upstream** port and run the gate on the cockpit-facing port:

```sh
# in bearbrowser-agent-machine, before exec-ing the sidecar binary:
export NOETICA_AM_PORT="${NOETICA_AM_UPSTREAM_PORT:-8091}"   # sidecar moves upstream
"$BIN" &                                                     # agent-machine on :8091
exec python3 "$SELF_DIR/bearbrowser-agent-machine-gate.py"   # gate on :8080 (cockpit target)
```
The gate reads `NOETICA_AM_UPSTREAM_PORT` (default 8091) and `BEARBROWSER_AM_GATE_PORT`
(default 8080). `cockpit-config.js` keeps pointing at the cockpit-facing port, now the
gate — so the resolver targets a *governed* endpoint transparently.

## Route classification (heuristic, security-first)
The gate maps `(method, path)` to a governance action (see `_RULES`). It is
deliberately conservative: known reads → allowed, known mutations → gated,
`/shell|/exec|/terminal|/fs|/credential|/egress|/governance` → prohibited, and any
**unrecognized non-GET route → a prohibited action (deny)**. Tighten the map as the
agent-machine `/api/*` surface stabilizes — but the default never fails open.
