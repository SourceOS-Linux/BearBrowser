# BearBrowser Feature Plane Operating Model

This document defines the first product feature plane for BearBrowser: local provenance, policy-visible actions, local memory candidates, and the agent sidecar status surface.

The goal is to make BearBrowser agentic by design without granting agents ambient authority.

## Scope

This feature plane applies to the current native WebKit bootstrap shell and the future Gecko-derived BearBrowser runtime.

It is intentionally engine-portable:

- The native shell can emit app/runtime/navigation events.
- The Gecko runtime can emit deeper navigation/tab/download/credential events later.
- Automation wrappers can emit observe/action proposal events now.
- Memory candidates can be proposed, held, committed, or rejected without a production engine.
- The sidecar can render local state without waiting for a production browser engine.

## Local State Layout

Default local state paths:

```text
~/Library/Application Support/BearBrowser/provenance/events.jsonl
~/Library/Application Support/BearBrowser/policy/actions.jsonl
~/Library/Application Support/BearBrowser/memory/candidates.jsonl
~/Library/Application Support/BearBrowser/sidecar/status.html
```

Linux equivalents should move under XDG paths:

```text
$XDG_STATE_HOME/bearbrowser/provenance/events.jsonl
$XDG_STATE_HOME/bearbrowser/policy/actions.jsonl
$XDG_STATE_HOME/bearbrowser/memory/candidates.jsonl
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

Writers:

```text
scripts/bearbrowser-propose-action.py
scripts/bearbrowser-resolve-action.py
```

Verifier:

```text
scripts/bearbrowser-verify-actions.py
```

Installed commands:

```text
bearbrowser-propose-action
bearbrowser-resolve-action
bearbrowser-verify-actions
```

Required properties:

- Every action has an action ID and decision ID.
- Every action has a risk level.
- Agent-runtime credential and autofill requests are denied by local default policy.
- Cross-tab sharing, uploads, automation, and memory writes default to `hold`.
- Held actions can be manually allowed or denied through a follow-up action record.
- Manual resolution emits a `policy.decision` provenance event.

## Memory Candidates

Memory candidates describe what the browser or agent proposes to remember.

Schema:

```text
schemas/memory-candidate.schema.json
```

Manager:

```text
scripts/bearbrowser-memory-candidate.py
```

Verifier:

```text
scripts/bearbrowser-verify-memory.py
```

Installed commands:

```text
bearbrowser-memory-candidate
bearbrowser-verify-memory
```

Required properties:

- New memories start as `candidate`.
- Candidate memories must default to policy decision `hold`.
- Persistent writes require explicit approval.
- Commit creates a follow-up `committed` record resolving the candidate.
- Reject creates a follow-up `rejected` record resolving the candidate.
- Sensitive-looking memory text is blocked before persistence and stored as `<REDACTED-SENSITIVE-MEMORY-CANDIDATE>`.
- Candidate creation emits `memory.candidate_created`.
- Commit emits `memory.committed`.
- Reject emits `memory.rejected`.

Example:

```bash
bearbrowser-memory-candidate create \
  --text 'Remember that this page is about SourceOS release planning.' \
  --source-kind page \
  --source-label sourceos-release-planning

bearbrowser-memory-candidate resolve \
  --latest-candidate \
  --decision reject \
  --reason 'Not useful enough to persist.'

bearbrowser-verify-memory
```

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

The sidecar status surface renders local event/action/memory state.

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

- Python syntax for event/action/memory/sidecar scripts.
- Shell syntax for feature verifiers.
- Provenance redaction invariants.
- Policy action classification and manual resolution invariants.
- Memory candidate lifecycle invariants.
- Sensitive-looking memory candidate blocking.
- Agent sidecar contract invariants.
- Sidecar status HTML/JSON generation, including memory visibility.

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

bearbrowser-resolve-action \
  --latest-held \
  --decision deny \
  --actor-type human \
  --actor-id "$USER" \
  --reason 'Do not share this page with an agent yet.'

bearbrowser-memory-candidate create \
  --text 'Remember that BearBrowser memory writes remain candidate-only until approval.' \
  --actor-type human \
  --actor-id "$USER" \
  --source-kind note \
  --source-label dogfood-memory-test

bearbrowser-memory-candidate resolve \
  --latest-candidate \
  --decision reject \
  --actor-type human \
  --actor-id "$USER" \
  --reason 'Rejecting this test memory candidate.'

bearbrowser-verify-provenance
bearbrowser-verify-actions
bearbrowser-verify-memory
bearbrowser-verify-agent-sidecar
bearbrowser-sidecar-status --format html --open
bearbrowser-status
```

Expected results:

- BearBrowser opens as native BearBrowser.
- `app.launch` is emitted automatically by `bearbrowser-open` and by the native shell.
- Manual navigation event is recorded.
- Page-sharing action is classified as `hold`, then resolved by manual denial.
- Memory candidate is created as `hold`, then rejected by manual denial.
- Provenance, action, and memory logs verify.
- Agent sidecar contract verifies.
- Sidecar status HTML opens with event/action/memory counts and recent records.

## Next Implementation Step

The next product step is to connect more native-shell controls to the feature plane directly:

1. Add a visible in-app action proposal control for page sharing.
2. Add a visible in-app memory-candidate control.
3. Add approve/reject controls in the sidecar status page or native shell.
4. Replace static HTML status with an interactive local sidecar surface.

After that, the same event/action/memory interfaces should be ported into the real Gecko runtime.
