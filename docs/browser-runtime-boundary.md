# BearBrowser Runtime Boundary Decision

## Purpose

`BrowserRuntimeBoundaryDecision` is a decision-only record for BearBrowser runtime, automation, credential, and workspace-bridge surfaces.

It exists to prevent BearBrowser from collapsing policy text, credential mediation, browser automation, authenticated-session state, downloads, workspace bridges, and provenance events into a single implicit allow.

## Boundary chain

```text
browser / operator / agent request = evidence input
Policy Fabric decision = policy admission
Agent Registry ref = agent identity / authority evidence
BrowserRuntimeBoundaryDecision = local decision-only boundary
BearBrowser automation / credential broker / workspace bridge = later runtime surface
Provenance event = redacted evidence record only
```

## Hard rules

A valid boundary decision must keep:

- `performedAction = false`
- `credentialExportAllowed = false`
- `inheritsHumanCredentials = false`
- `nonLoopbackControlAllowed = false`
- `nativeExecutionAllowed = false`
- `declaredWorkspaceScopeOnly = true`
- `secretValuesLogged = false`
- `sessionMaterialLogged = false`
- `paymentMaterialLogged = false`

Agent actors must carry an Agent Registry ref. Policy decisions must be explicit refs. Evidence must be refs, not raw secrets or session material.

## Validation

```bash
python3 scripts/verify-browser-runtime-boundary.py
```

The verifier validates the good agent automation fixture and rejects fixtures that attempt credential export or raw secret logging.

## Related surfaces

- `TRUST_SURFACE.yaml`
- `policy/credential-broker-contract.yaml`
- `scripts/policy-surface`
- `scripts/credential-surface`
- `docs/provenance-events.md`

## Non-goals

This tranche does not execute browser automation, grant credential access, submit forms, bridge downloads to workspaces, send native messages, open non-loopback control, or mutate profiles. It only adds the boundary record and validation path.
