# BearBrowser ADR-035 Component Inspector and Engine Manifests

## Decision (issue BearBrowser #33)

BearBrowser adopts the `prophet-platform` ADR-035 transparent fault attribution contract family.
All browser sub-engines (renderer, network, credential broker, Tor circuit, agent sidecar) declare
an `EngineManifest`. Boundary crossings emit `BoundaryTransition` events. Faults surface as
`FaultEnvelope` records. These are consumed by the SourceOS agent sidecar, agentplane, and
the BearBrowser component inspector panel.

**Upstream dependency**: `SocioProphet/prophet-platform` squash `86b0fbc203b595fb7ef103ee06f845211ea46378`

## Component Inspector

The component inspector is a browser-native devtools panel that shows:

1. All `EngineManifest` records for active sub-engines
2. Live `BoundaryTransition` stream (scrollable, filterable by `boundaryKind` and `decision`)
3. `FaultEnvelope` log with severity indicators

Opening: `bear://inspect` or `Ctrl+Shift+B` (operator mode).

### Panel layout

```
┌─────────────────────────────────────────────────────────────────┐
│ BearBrowser Component Inspector                         [×] [↗]  │
├────────────────┬────────────────────────────────────────────────┤
│ Engines (5)    │ Boundary Transitions                           │
│ ○ renderer     │  admitted  file-read       2026-07-18 12:00:01 │
│ ○ network      │  admitted  network-fetch   2026-07-18 12:00:02 │
│ ○ cred-broker  │  suppressed clipboard-read  2026-07-18 12:01:00 │
│ ○ tor-circuit  │  admitted  network-fetch   2026-07-18 12:01:05 │
│ ○ agent-sidecar│  admitted  file-read       2026-07-18 12:01:10 │
├────────────────┴────────────────────────────────────────────────┤
│ Fault Log                                                        │
│  [non-fatal] render-failure — iframe sandbox violation caught    │
│  [fatal]     policy-violation — network-fetch denied by org      │
└─────────────────────────────────────────────────────────────────┘
```

## EngineManifest Fixtures

### Renderer (gecko engine)

```json
{
  "id": "urn:srcos:engine-manifest:bearbrowser:renderer:2026",
  "specVersion": "0.1.0",
  "engineKind": "browser-child",
  "engineId": "bearbrowser-renderer",
  "version": "2026.07",
  "declaredBoundaries": ["file-read", "dom-emit", "network-fetch", "render-emit"],
  "allowedInputKinds": ["text/html", "text/css", "application/javascript", "application/wasm"],
  "sideEffectPolicy": "allowed-with-receipt",
  "networkEgressPolicy": "policy-gated",
  "sandboxKind": "browser-origin-sandbox",
  "capabilityContractRef": "urn:srcos:capability-contract:bearbrowser-renderer:2026",
  "orgPolicyRef": "urn:srcos:org-policy:default:2026"
}
```

### Network engine

```json
{
  "id": "urn:srcos:engine-manifest:bearbrowser:network:2026",
  "specVersion": "0.1.0",
  "engineKind": "network-observer",
  "engineId": "bearbrowser-network",
  "version": "2026.07",
  "declaredBoundaries": ["network-fetch", "dns-resolve"],
  "allowedInputKinds": ["application/x-http-request", "application/x-https-request"],
  "sideEffectPolicy": "allowed-with-receipt",
  "networkEgressPolicy": "policy-gated",
  "sandboxKind": "ambient-user-session",
  "capabilityContractRef": "urn:srcos:capability-contract:bearbrowser-network:2026",
  "orgPolicyRef": "urn:srcos:org-policy:default:2026"
}
```

### Credential broker

```json
{
  "id": "urn:srcos:engine-manifest:bearbrowser:cred-broker:2026",
  "specVersion": "0.1.0",
  "engineKind": "broker",
  "engineId": "bearbrowser-credential-broker",
  "version": "2026.07",
  "declaredBoundaries": ["credential-read", "credential-write"],
  "allowedInputKinds": ["application/x-credential-request"],
  "sideEffectPolicy": "allowed-with-receipt",
  "networkEgressPolicy": "denied",
  "sandboxKind": "process-isolated",
  "capabilityContractRef": "urn:srcos:capability-contract:bearbrowser-cred-broker:2026",
  "orgPolicyRef": "urn:srcos:org-policy:default:2026"
}
```

### Tor circuit engine

```json
{
  "id": "urn:srcos:engine-manifest:bearbrowser:tor-circuit:2026",
  "specVersion": "0.1.0",
  "engineKind": "network-observer",
  "engineId": "bearbrowser-tor-circuit",
  "version": "2026.07",
  "declaredBoundaries": ["network-fetch", "circuit-establish", "circuit-close"],
  "allowedInputKinds": ["application/x-tor-circuit-request"],
  "sideEffectPolicy": "allowed-with-receipt",
  "networkEgressPolicy": "tor-gated",
  "sandboxKind": "process-isolated",
  "capabilityContractRef": "urn:srcos:capability-contract:bearbrowser-tor:2026",
  "orgPolicyRef": "urn:srcos:org-policy:default:2026"
}
```

### Agent sidecar

```json
{
  "id": "urn:srcos:engine-manifest:bearbrowser:agent-sidecar:2026",
  "specVersion": "0.1.0",
  "engineKind": "agent",
  "engineId": "bearbrowser-agent-sidecar",
  "version": "2026.07",
  "declaredBoundaries": ["file-read", "dom-read", "network-fetch"],
  "allowedInputKinds": ["application/x-agent-sidecar-request"],
  "sideEffectPolicy": "allowed-with-receipt",
  "networkEgressPolicy": "policy-gated",
  "sandboxKind": "process-isolated",
  "capabilityContractRef": "urn:srcos:capability-contract:bearbrowser-agent-sidecar:2026",
  "orgPolicyRef": "urn:srcos:org-policy:default:2026"
}
```

## BoundaryTransition Fixtures

### Network fetch (admitted, normal browse)

```json
{
  "id": "urn:srcos:boundary-transition:bearbrowser:net-fetch-20260718T120000Z",
  "specVersion": "0.1.0",
  "engineRef": "urn:srcos:engine-manifest:bearbrowser:network:2026",
  "boundaryKind": "network-fetch",
  "direction": "egress",
  "decision": "admitted",
  "policyDecisionRef": "urn:srcos:policy-decision:bearbrowser-net-admit-20260718",
  "targetOriginRedacted": true,
  "observedAt": "2026-07-18T12:00:00Z"
}
```

### Clipboard read (suppressed — org policy)

```json
{
  "id": "urn:srcos:boundary-transition:bearbrowser:clipboard-read-20260718T120100Z",
  "specVersion": "0.1.0",
  "engineRef": "urn:srcos:engine-manifest:bearbrowser:renderer:2026",
  "boundaryKind": "clipboard-read",
  "direction": "ingress",
  "decision": "suppressed",
  "suppressionReason": "org policy: clipboard-read denied in restricted session",
  "policyDecisionRef": "urn:srcos:policy-decision:bearbrowser-clipboard-deny-20260718",
  "observedAt": "2026-07-18T12:01:00Z"
}
```

### Network fetch through Tor (admitted)

```json
{
  "id": "urn:srcos:boundary-transition:bearbrowser:tor-net-20260718T120200Z",
  "specVersion": "0.1.0",
  "engineRef": "urn:srcos:engine-manifest:bearbrowser:tor-circuit:2026",
  "boundaryKind": "network-fetch",
  "direction": "egress",
  "decision": "admitted",
  "policyDecisionRef": "urn:srcos:policy-decision:bearbrowser-tor-net-admit-20260718",
  "targetOriginRedacted": true,
  "circuitRedacted": true,
  "observedAt": "2026-07-18T12:02:00Z"
}
```

## FaultEnvelope Fixtures

### Renderer: iframe sandbox violation (non-fatal)

```json
{
  "id": "urn:srcos:fault-envelope:bearbrowser:iframe-sandbox-20260718T130000Z",
  "specVersion": "0.1.0",
  "engineRef": "urn:srcos:engine-manifest:bearbrowser:renderer:2026",
  "faultClass": "render-failure",
  "severity": "non-fatal",
  "recoveryAction": "continue-limited",
  "recoveryOutcome": "succeeded",
  "humanReviewRequired": false,
  "observedAt": "2026-07-18T13:00:00Z",
  "note": "Iframe sandbox blocked eval(). Renderer continued with restricted execution context."
}
```

### Network: org policy violation (fatal)

```json
{
  "id": "urn:srcos:fault-envelope:bearbrowser:net-policy-20260718T140000Z",
  "specVersion": "0.1.0",
  "engineRef": "urn:srcos:engine-manifest:bearbrowser:network:2026",
  "faultClass": "policy-violation",
  "severity": "fatal",
  "policyDecisionRef": "urn:srcos:policy-decision:bearbrowser-net-deny-20260718",
  "recoveryAction": "refuse-start",
  "recoveryOutcome": "succeeded",
  "humanReviewRequired": true,
  "humanReviewRef": "urn:srcos:review-request:bearbrowser-net-policy-20260718",
  "observedAt": "2026-07-18T14:00:00Z",
  "note": "Org policy denied network-fetch to non-allowlisted origin. Request blocked. Human review queued."
}
```

## Related

- `docs/browser-runtime-boundary.md` — browser runtime boundary contract
- `docs/provenance-events.md` — provenance event schema
- sourceos-shell `docs/adr-035-examples.md` — reference fixtures
- sourceos-spec `CapabilityContract.json` — capability declaration schema
