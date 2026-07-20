# Cockpit Receipts — the trust surface

The 5th surface of `docs/cockpit-spec.md` §2, and the one no incumbent can copy: a
live, verifiable ledger of **every governed decision** the enforcing bridge made —
across all three surfaces — presented to the user.

Gartner told enterprises to *block* agentic browsers because "controls to inspect
agent intent do not exist at scale." Receipts is that control, made visible: a
running, signed log of every action the user's agents proposed and exactly what
policy did about it.

## One stream, three surfaces
`agent-control-bridge.py` attests every decision as a safe-trace `ReasoningEvent` to
one append-only stream (`reasoning-events.ndjson`):

| prefix | surface | contract |
|---|---|---|
| `browser.*` | the governed browser | `agentActionContract` |
| `iot.*` | the smart-home / IoT estate | `iotActionContract` |
| `agent.*` | the cockpit's local agent | `agentMachineActionContract` (Lane 4) |

`scripts/bearbrowser-receipts.py` reads that one stream and serves it as the ledger.
It derives the surface from the event-type prefix, so it unifies all three
automatically — a `browser.navigate` permit, an `iot.unlock-door` violation, and an
`agent.execute-shell` block all land in the same feed.

## API (loopback-only, read-only)
```
GET /health                       liveness + stream location
GET /receipts                     parsed receipts, newest first
     ?surface=browser|iot|agent   filter by surface
     &decision=permit|deny        filter by verdict
     &violations=1                only policy violations
     &since=<ISO8601>&limit=N
GET /receipts/summary             counts by surface / decision / class + violations
GET /receipts/stream              Server-Sent Events live tail (new receipts)
```
The cockpit's Receipts panel (client-vue) fetches `/receipts` + subscribes to
`/receipts/stream` — pointed at this loopback service by the resolver
(`window.__COCKPIT_CONFIG__`). Nothing reaches off-device; the loopback bind is the
security boundary (CORS is permissive because the payload is read-only, non-secret).

## Each receipt
```jsonc
{ "id": "...", "at": "2026-…Z", "surface": "agent",
  "action": "execute-shell", "eventType": "agent.policy.violation",
  "decision": "deny", "class": "prohibited", "violation": true,
  "reason": "PROHIBITED action 'execute-shell' BLOCKED at decision time",
  "runRef": "...", "policyRef": "...", "trustLevel": "trusted-control-input",
  "traceLevel": "workspace-safe" }
```
Safe-trace by construction: the summary carries the action + verdict, never raw page
content, secret values, or private reasoning.

## Verify
`scripts/tests/test_receipts.py` — seeds real browser + iot decisions via the bridge
plus a synthetic `agent.*` event, then asserts the projection, filters, and summary:
7 receipts, 3 surfaces unified, 3 violations flagged, 4 permits / 3 denies.

Wire alongside the other loopback sidecars (`bearbrowser-sidecar-server`,
`bearbrowser-agent-machine-gate`, the Rust `iot-sidecar`); the browser rewrites the
ephemeral port into `cockpit-config.js` at launch, same as the rest.
