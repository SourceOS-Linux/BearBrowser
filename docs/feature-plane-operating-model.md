# BearBrowser Feature Plane Operating Model

This document defines the first product feature plane for BearBrowser: local provenance, policy-visible actions, local memory candidates, governance queue, and the interactive agent sidecar surface.

The goal is to make BearBrowser agentic by design without granting agents ambient authority.

## Scope

This feature plane applies to the current native WebKit bootstrap shell and the future Gecko-derived BearBrowser runtime.

It is intentionally engine-portable:

- The native shell can emit app/runtime/navigation events.
- The Gecko runtime can emit deeper navigation/tab/download/credential events later.
- Automation wrappers can emit observe/action proposal events now.
- Memory candidates can be proposed, held, committed, or rejected without a production engine.
- The governance queue can show unresolved held actions and pending memory.
- The interactive sidecar can render and resolve local governance state without waiting for a production browser engine.

## Local State Layout

Default local state paths:

```text
~/Library/Application Support/BearBrowser/provenance/events.jsonl
~/Library/Application Support/BearBrowser/policy/actions.jsonl
~/Library/Application Support/BearBrowser/memory/candidates.jsonl
~/Library/Application Support/BearBrowser/sidecar/status.html
~/Library/Application Support/BearBrowser/sidecar/server-token
```

Linux equivalents should move under XDG paths:

```text
$XDG_STATE_HOME/bearbrowser/provenance/events.jsonl
$XDG_STATE_HOME/bearbrowser/policy/actions.jsonl
$XDG_STATE_HOME/bearbrowser/memory/candidates.jsonl
$XDG_STATE_HOME/bearbrowser/sidecar/status.html
$XDG_STATE_HOME/bearbrowser/sidecar/server-token
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

## Governance Queue

The governance queue describes what still needs user or policy attention.

Queue command:

```text
scripts/bearbrowser-governance-queue.py
```

Installed command:

```text
bearbrowser-governance-queue
```

The queue reports:

- unresolved held policy actions;
- pending memory candidates;
- compact action and memory metadata;
- recommended resolution commands.

Example:

```bash
bearbrowser-governance-queue
bearbrowser-governance-queue --format json
bearbrowser-governance-queue --fail-on-pending
```

The queue is intentionally local and conservative. It should not silently resolve anything.

## Interactive Local Sidecar

The interactive local sidecar is a localhost-only HTTP server with token-gated resolution forms.

Server:

```text
scripts/bearbrowser-sidecar-server.py
```

Launcher:

```text
scripts/bearbrowser-sidecar-open.sh
```

Verifier:

```text
scripts/verify-interactive-sidecar.sh
```

Installed commands:

```text
bearbrowser-sidecar-server
bearbrowser-sidecar-open
bearbrowser-verify-interactive-sidecar
```

Security rules:

- Binds only to `127.0.0.1` or `localhost`.
- Uses a local token in `~/Library/Application Support/BearBrowser/sidecar/server-token`.
- Rejects non-token requests.
- Does not expose raw secret values.
- Uses existing local resolver scripts for allow/deny/commit/reject.
- Resolution writes action, memory, and provenance logs.

Example:

```bash
bearbrowser-sidecar-open --open
bearbrowser-sidecar-server --print-url
bearbrowser-verify-interactive-sidecar
```

## Native Shell Controls

The native WebKit shell exposes the first in-app governance loop.

Current controls:

- `Propose Share`: creates a held `share_page_with_agent` action and emits `page.shared_with_agent`.
- `Memory Candidate`: prompts for candidate text, creates a held `write_memory_candidate` action, writes a memory candidate, and emits `memory.candidate_created`.
- `Resolve Held`: lets the user allow or deny the latest held action, or commit or reject the latest memory candidate.
- `Sidecar Status`: starts or reuses the interactive localhost sidecar and loads its tokenized URL in the native shell.

Native source:

```text
native/macos/BearBrowserWebKitLauncher.m
```

Native verifier:

```text
scripts/verify-native-macos-shell.sh
```

Installed command:

```text
bearbrowser-verify-native-shell
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

## Static Sidecar Status Surface

The static sidecar status surface renders local event/action/memory state. It remains useful for diagnostics and CI, but the native shell now prefers the interactive sidecar server.

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

## CI Validation

Workflow:

```text
.github/workflows/feature-plane.yml
```

CI validates:

- Python syntax for event/action/memory/queue/static-sidecar/interactive-sidecar scripts.
- Shell syntax for feature verifiers.
- Provenance redaction invariants.
- Policy action classification and manual resolution invariants.
- Governance queue counts before and after resolution.
- Memory candidate lifecycle invariants.
- Sensitive-looking memory candidate blocking.
- Interactive localhost sidecar token and resolution flows.
- Agent sidecar contract invariants.
- Static sidecar status HTML/JSON generation, including memory visibility.

Native shell workflow:

```text
.github/workflows/native-macos-shell.yml
```

Native shell CI validates:

- source and landing page existence;
- native governance controls;
- native event emission strings;
- native interactive sidecar integration;
- native macOS compile on `macos-latest`;
- no release artifacts.

These workflows intentionally do not build browser binaries and do not produce release artifacts.

## Tomorrow Dogfood Path

After reinstalling the formula, the minimal dogfood sequence is:

```bash
brew update
brew reinstall --formula SourceOS-Linux/tap/bearbrowser

bearbrowser-install-app-launcher
bearbrowser-reset-bootstrap --clear-log
bearbrowser-open
sleep 2

bearbrowser-governance-queue
bearbrowser-sidecar-open --open
bearbrowser-verify-interactive-sidecar
bearbrowser-verify-provenance
bearbrowser-verify-actions
bearbrowser-verify-memory --allow-empty
bearbrowser-verify-agent-sidecar
bearbrowser-verify-native-shell
bearbrowser-status
```

Then dogfood the native shell controls directly:

```text
Propose Share
Memory Candidate
Resolve Held
Sidecar Status
```

Expected results:

- BearBrowser opens as native BearBrowser.
- `app.launch` is emitted automatically by `bearbrowser-open` and by the native shell.
- Native controls create held actions and memory candidates.
- `Resolve Held` can allow/deny/commit/reject from inside BearBrowser.
- `Sidecar Status` loads the interactive tokenized localhost sidecar.
- Interactive sidecar can allow/deny held actions and commit/reject memory candidates.
- Governance queue shows pending items before resolution and clears after resolution.
- Provenance, action, memory, agent sidecar, interactive sidecar, and native shell verifiers pass.

## Next Implementation Step

The next product step is to add a read-only current-page summary proposal surface:

1. Capture visible page text metadata safely from the native shell.
2. Create `summarize_page` action proposals without mutation.
3. Render the proposal in the interactive sidecar.
4. Keep the same provenance/action/memory interfaces so this can later move into the Gecko runtime.
