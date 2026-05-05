# BearBrowser Feature Plane Operating Model

This document defines the first product feature plane for BearBrowser: local provenance, policy-visible actions, and the agent sidecar status surface.

The goal is to make BearBrowser agentic by design without granting agents ambient authority.

## Scope

This feature plane applies to the current native WebKit bootstrap shell and the future Gecko-derived BearBrowser runtime.

It is intentionally engine-portable:

- The native shell can emit app/runtime events.
- The Gecko runtime can emit navigation/tab/download/credential events later.
- Automation wrappers can emit observe/action proposal events now.
- The sidecar can render local state without waiting for a production browser engine.

## Local State Layout

Default local state paths:

```text
~/Library/Application Support/BearBrowser/provenance/events.jsonl
~/Library/Application Support/BearBrowser/policy/actions.jsonl
~/Library/Application Support/BearBrowser/sidecar/status.html
```

Linux equivalents should move under XDG paths:

```text
$XDG_STATE_HOME/bearbrowser/provenance/events.jsonl
$XDG_STATE_HOME/bearbrowser/policy/actions.jsonl
$XDG_STATE_HOME/bearbrowser/sidecar/status.html
```

## Provenance Events

Provenance events describe what happened.

Schema:

```text
schemas/provenance-event.schema.json
```

Writer:

```text
scripts/bearbrowser-emit-event.py
```

Verifier:

```text
scripts/bearbrowser-verify-provenance.py
```

Installed commands:

```text
bearbrowser-emit-event
bearbrowser-verify-provenance
```

Required properties:

- `product` must be `BearBrowser`.
- `schemaVersion` must be `bearbrowser.provenance.v1`.
- `redaction.secretValuesLogged` must be `false`.
- Secret-like keys are replaced with `<REDACTED>` before logging.
- Every event includes a policy object, even when the decision is `not_applicable`.

## Policy Actions

Policy action records describe what was requested before privileged work happens.

Schema:

```text
schemas/policy-action.schema.json
```

Writer:

```text
scripts/bearbrowser-propose-action.py
```

Verifier:

```text
scripts/bearbrowser-verify-actions.py
```

Installed commands:

```text
bearbrowser-propose-action
bearbrowser-verify-actions
```

Required properties:

- Every action has an action ID and decision ID.
- Every action has a risk level.
- Agent-runtime credential and autofill requests are denied by local default policy.
- Cross-tab sharing, uploads, automation, and memory writes default to `hold`.

## Local Default Policy

Default action classification lives at:

```text
policy/local-default-actions.yaml
```

The default policy is intentionally conservative:

- Human navigation can be allowed.
- Page summarization can be observed.
- Cross-tab comparison is held.
- Page sharing with agents is held.
- Agent-runtime credential access is denied.
- Automation is held.
- Persistent memory writes are held.

PolicyFabric replaces local defaults when it is available, but local defaults must remain safe enough for offline operation.

## Agent Sidecar Contract

The sidecar contract defines UX modes and authority boundaries.

Contract:

```text
agent-sidecar/contract.yaml
```

Verifier:

```text
scripts/verify-agent-sidecar-contract.py
```

Installed command:

```text
bearbrowser-verify-agent-sidecar
```

Mandatory sidecar surfaces:

- `current-page-summary`
- `selected-tab-compare`
- `action-proposal`
- `memory-candidate`
- `credential-boundary`

The governing principle is:

```text
Agents observe and propose; PolicyFabric and the user grant authority.
```

## Sidecar Status Surface

The sidecar status surface renders local event/action state.

Renderer:

```text
scripts/bearbrowser-sidecar-status.py
```

Verifier:

```text
scripts/verify-sidecar-status.sh
```

Installed commands:

```text
bearbrowser-sidecar-status
bearbrowser-verify-sidecar-status
```

Supported render modes:

```text
bearbrowser-sidecar-status --format text
bearbrowser-sidecar-status --format json
bearbrowser-sidecar-status --format html --open
```

The HTML output is not the final sidebar UI. It is the first local status surface for dogfooding and validating product semantics.

## CI Validation

Workflow:

```text
.github/workflows/feature-plane.yml
```

CI validates:

- Python syntax for event/action/sidecar scripts.
- Shell syntax for feature verifiers.
- Provenance redaction invariants.
- Policy action classification invariants.
- Agent sidecar contract invariants.
- Sidecar status HTML/JSON generation.

This workflow intentionally does not build browser binaries and does not produce release artifacts.

## Tomorrow Dogfood Path

After reinstalling the formula, the minimal dogfood sequence is:

```bash
brew update
brew reinstall --formula SourceOS-Linux/tap/bearbrowser

bearbrowser-install-app-launcher
bearbrowser-reset-bootstrap --clear-log
bearbrowser-open
sleep 2

bearbrowser-emit-event --event-type navigation.requested \
  --surface native-shell \
  --profile bootstrap \
  --actor-type human \
  --actor-id "$USER" \
  --decision allow \
  --policy-mode local-default \
  --payload '{"url":"https://socioprophet.com","source":"manual-test"}'

bearbrowser-propose-action \
  --action-type share_page_with_agent \
  --profile bootstrap \
  --actor-type human \
  --actor-id "$USER" \
  --target-kind page \
  --target-label current-page

bearbrowser-verify-provenance
bearbrowser-verify-actions
bearbrowser-verify-agent-sidecar
bearbrowser-sidecar-status --format html --open
bearbrowser-status
```

Expected results:

- BearBrowser opens as native BearBrowser.
- `app.launch` is emitted automatically by `bearbrowser-open`.
- Manual navigation event is recorded.
- Page-sharing action is classified as `hold`.
- Provenance and action logs verify.
- Agent sidecar contract verifies.
- Sidecar status HTML opens with event/action counts and recent records.

## Next Implementation Step

The next product step is to connect the native WebKit shell to the feature plane directly:

1. Emit `app.launch` from the native app itself.
2. Emit `navigation.requested` and `navigation.committed` from the address bar.
3. Add a native sidecar/status button that opens the generated sidecar status surface.
4. Add an in-app summary placeholder that creates a held `summarize_page`/`share_page_with_agent` action proposal.

After that, the same event/action interfaces should be ported into the real Gecko runtime.
