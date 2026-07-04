# BearBrowser Agent Control Bridge

The evidence-emitting control-bridge specification: how TurtleTerm's copilot
drives BearBrowser's `agent-runtime` profile under the governance contract
(`policy/bearbrowser-contract.yaml`), with every action gated by policy and
attested by a replayable reasoning trace.

This is the moat. No other browser ships a spec-governed, evidence-emitting
agent automation surface. The contract + bridge are the differentiating IP and
are ready the moment the binary lands.

> **Status — the ENFORCING bridge is implemented; runtime binding is pending the binary.**
> The control bridge is real and runnable today:
> **`scripts/agent-control-bridge.py`**. Its enforcement + attestation layer is
> **pure** — it classifies every agent action against the contract and BLOCKS
> gated/prohibited (including injected) actions **at decision time**, attesting a
> spec-conformant `ReasoningEvent` for each, *without needing a live browser*
> (dry/enforce-only mode). Containment is proven by
> **`scripts/tests/test_injection_containment.py`** (79 assertions, all passing):
> an injected `enter-credentials` is denied + a `browser.policy.violation` is
> attested; a `submit-form`/`cross-origin-post` without a per-action approval
> token is denied; a `click` the planner flags as a submit, or a fill into a
> credential/payment/gov-id field, is re-classified and blocked.
>
> The **live transport is now wired**: `connect()` opens a real WebDriver-BiDi
> WebSocket to the loopback control endpoint, authenticates with the per-session
> token, and completes the `session.new` handshake
> (`lib/bidi_transport.py::BidiClient`); `dispatch()` gates every action FIRST and
> only then puts the mapped BiDi command on the wire. Because BearBrowser has no
> compiled binary yet (the LibreWolf compile lane is wired in
> `scripts/bearbrowser-build-binary.sh` but has not been run), there is no live
> endpoint to attach to on this machine, so `connect()` returns `False` and the
> bridge falls through to enforce-only mode — enforcement and attestation are
> unchanged either way. The transport itself is proven against a mock BiDi
> WebSocket server in `scripts/tests/test_bidi_transport.py` (20 assertions): a
> permitted `navigate` drives the mock browser; an injected `enter-credentials`
> and an un-approved gated `submit-form` put **ZERO** commands on the wire. The
> emission schema is **identical to TurtleTerm's** reasoning-event family, so the
> evidence fabric is already unified across the two products. The reference
> emitter is `TurtleTerm/assets/sourceos/bin/turtle-agentd`
> (`_open_reasoning_run`, `_emit_reasoning_event`, `_close_reasoning_run`); the
> browser bridge mirrors those exact shapes. The machine-readable action→class
> map + PolicyConditions the bridge loads live in
> `policy/bearbrowser-contract.yaml` under `spec.agentActionContract`.

---

## 1. Transport

### Recommended surface: WebDriver-BiDi

The agent drives BearBrowser over **WebDriver-BiDi**, the Gecko-native,
bidirectional automation protocol (the W3C successor to classic WebDriver,
implemented by the Firefox/LibreWolf "Remote Agent" / Marionette stack on which
BearBrowser is built). BiDi is the correct mechanism here because:

- It is **native to the Gecko engine** BearBrowser is built on — no CDP shim, no
  out-of-process driver translating commands.
- It is **bidirectional**: the browser pushes events (navigation, network,
  log) the bridge needs to emit accurate `ReasoningEvent`s, not just
  request/response RPC.
- It is **standards-track** (W3C), so the surface is stable and auditable.

CDP (Chrome DevTools Protocol) is supported by Gecko only as a partial
compatibility layer; BiDi is the first-class path and is what this spec targets.
Playwright/Stagehand (see `docs/runtime-automation.md`) ride on top of BiDi.

### Hardening — loopback-only, token-gated, off by default

The control endpoint is exposed **only** under these conditions:

| Property            | Value                                                            |
|---------------------|------------------------------------------------------------------|
| Bind address        | `127.0.0.1` (loopback only; never `0.0.0.0`)                     |
| Port                | Ephemeral, allocated per session                                 |
| Default state       | **Off.** Opt-in per session (`agentRuntime.devtools.remoteDebugging.defaultDecision: deny` in the contract) |
| Auth                | Per-session bearer token; required on every BiDi message         |
| Token lifetime      | Session-scoped; destroyed on `cleanupOnExit`                     |
| TLS                 | Not required on loopback; token is the auth boundary             |

The contract's `agentRuntime.devtools.remoteDebugging` block already declares
`bindAddress: 127.0.0.1`, `requireEphemeralPort: true`, `requireSessionToken:
true`, and a default decision of `deny`. The `agent-runtime` profile overlay
(`settings/profiles/agent-runtime/user-overlay.js`) sets the BiDi prefs to match.

The loopback range (`127.0.0.0/8`) is in the contract's network **denyCidrs** —
the control endpoint is the *only* permitted loopback surface, and the page
itself can never reach it.

### The BiDi client (`lib/bidi_transport.py`)

The transport is a **minimal, stdlib-first** WebDriver-BiDi WebSocket client:

- **Stdlib by default.** `BidiClient` speaks RFC 6455 over a raw socket
  (hand-rolled client-masked framing) — **zero third-party deps**. A live
  loopback browser can be driven with nothing but the standard library.
- **One optional dep, guarded.** If the `websocket-client` package is installed
  it is used for the wire instead (behind a guarded import); if it is absent the
  stdlib client covers the live path and enforce-only mode never needs it at all.
- **Loopback-mandatory.** A non-loopback `bidi_url` raises `BidiError` **before
  any socket is opened**. `connect()` mirrors this and returns `False`.
- **Handshake.** Construction opens the WebSocket, carries the per-session token
  (bearer header for the dep client; in-band `sessionToken` for the stdlib
  client), and completes `session.new`, capturing the `sessionId`.
- **`send_command(method, params) -> result`** writes one `{id, method, params}`
  frame, skips any async event pushes, and returns the matching `{id, result}`
  (raising `BidiError` on `{id, error}`).

### The gate sits BEFORE the wire (`dispatch`)

`ControlBridge.dispatch(action, params, approval_token)` is the real entry point
and enforces the ordering that makes containment true at the transport edge:

1. `evaluate_action(...)` runs **first** — pure policy, no wire touched.
2. If the decision is **not** permit, `dispatch` attests the violation/deny and
   **returns without constructing a single BiDi frame.** A denied or injected
   action can never reach `send_command`.
3. Only on **permit** does it map the action to a BiDi command
   (`build_bidi_command`) and send it — or, if no browser is connected, stay
   enforce-only ("would-permit").

`build_bidi_command` is pure data translation with **no policy authority**: the
gated/prohibited action names map to `None` (never a command) as a
defense-in-depth backstop even if it were somehow reached without the gate. The
result summary written to the trace is safe (shape/keys/sizes only) — never raw
DOM text, screenshot bytes, or field values.

### Action → BiDi command map

| Action (permitted) | BiDi method                          |
|--------------------|--------------------------------------|
| navigate           | `browsingContext.navigate`           |
| read-dom / extract-text / query-selector | `script.evaluate`   |
| scroll / wait      | `script.evaluate`                    |
| click              | `input.performActions` (pointer)     |
| fill-form-field*   | `input.performActions` (key)         |
| screenshot         | `browsingContext.captureScreenshot`  |
| *any gated/prohibited action* | **no command** (`None`)   |

\* only the allowed, non-credential/payment/gov-id fill shape reaches a command;
credential/payment/gov-id fills are reclassified to prohibited upstream and map
to no command.

### CLI

```
agent-control-bridge --bidi-url ws://127.0.0.1:9222 --bidi-token T \
                     --action navigate --url example.com
```

drives the live browser when the loopback endpoint is reachable, and reports
`transport: no browser -> enforce-only` when it is not — the decision and
attestation are identical either way.

---

## 2. Action lifecycle

Every agent action flows through the same six-step lifecycle. Steps 2, 4, and 6
emit canonical reasoning objects (specVersion `"2.0.0"`).

```
  ┌──────────────────────────────────────────────────────────────────┐
  │ 1. SESSION OPEN     → _open_reasoning_run()  ⇒ ReasoningRun         │
  │ 2. PER ACTION:                                                     │
  │    a. classify against contract (allowed | gated | prohibited)     │
  │    b. if gated → request approval; emit PolicyDecision             │
  │    c. if prohibited → deny; emit ReasoningEvent browser.policy.violation │
  │    d. execute via BiDi (allowed, or gated+approved)                │
  │    e. _emit_reasoning_event()  ⇒ ReasoningEvent  (summary only)     │
  │ 3. SESSION CLOSE    → _close_reasoning_run() ⇒ ReasoningReceipt     │
  └──────────────────────────────────────────────────────────────────┘
```

### Step 1 — open the run

On session start the bridge opens a `ReasoningRun`
(`$id https://schemas.srcos.ai/v2/ReasoningRun.json`). Mirrors
`turtle-agentd._open_reasoning_run`:

```json
{
  "id": "urn:srcos:reasoning-run:9f2c…",
  "type": "ReasoningRun",
  "specVersion": "2.0.0",
  "status": "running",
  "task": {
    "id": "urn:srcos:reasoning-task:9f2c…",
    "title": "Browser session: research pricing pages"
  },
  "agentRef": "urn:srcos:agent:turtle-copilot",
  "workspaceRef": "urn:srcos:workspace:default",
  "safeTrace": {
    "mode": "operational-trace-only",
    "rawPrivateReasoning": "not-collected",
    "eventCount": 0
  },
  "eventRefs": [],
  "artifactRefs": [],
  "startedAt": "2026-06-21T18:00:00Z"
}
```

### Step 2 — emit a ReasoningEvent per action

Each action emits one `ReasoningEvent`
(`$id https://schemas.srcos.ai/v2/ReasoningEvent.json`). `eventType` is
`browser.<action>`. The `summary` is a **safe description** — e.g.
`"navigated to example.com"` — and **never** full page content. Page content is
`untrusted-observation`. Mirrors `turtle-agentd._emit_reasoning_event` (including
the 500-char summary cap):

```json
{
  "id": "urn:srcos:reasoning-event:1a44…",
  "type": "ReasoningEvent",
  "specVersion": "2.0.0",
  "runRef": "urn:srcos:reasoning-run:9f2c…",
  "eventType": "browser.navigate",
  "summary": "navigated to example.com",
  "traceLevel": "workspace-safe",
  "trustLevel": "untrusted-observation",
  "capturedAt": "2026-06-21T18:00:01Z"
}
```

**Safe-trace boundary.** `traceLevel ∈ {public-safe, workspace-safe,
operator-private, restricted}` and `trustLevel ∈ {trusted-control-input,
trusted-workspace-source, semi-trusted-project-source, untrusted-observation,
restricted-material}`. Agent control intent is `trusted-control-input`; observed
page data is `untrusted-observation`. Secrets are masked (`mask_fields`
obligation); raw page text is never written to the trace.

### Step 4 — emit a PolicyDecision for gated actions

When an action classifies as **gated**, the bridge requests per-action approval
and emits a policy-decision (also carried as a `ReasoningEvent` of eventType
`browser.policy.decision`, with the structured decision in `extra`):

```json
{
  "id": "urn:srcos:reasoning-event:7b91…",
  "type": "ReasoningEvent",
  "specVersion": "2.0.0",
  "runRef": "urn:srcos:reasoning-run:9f2c…",
  "eventType": "browser.policy.decision",
  "summary": "gated action 'file-download' approved by operator",
  "traceLevel": "workspace-safe",
  "trustLevel": "trusted-control-input",
  "capturedAt": "2026-06-21T18:01:10Z",
  "decision": "permit",
  "policyRef": "urn:srcos:policy:bearbrowser-agent-runtime",
  "actionClass": "gated",
  "approvalTokenRef": "urn:srcos:approval:…"
}
```

A **prohibited** action emits `eventType: browser.policy.violation` with
`decision: "deny"` and is never executed — no approval token can unlock it.

### Step 6 — close with a ReasoningReceipt

On session close the bridge writes the `ReasoningReceipt`
(`$id https://schemas.srcos.ai/v2/ReasoningReceipt.json`). `traceHash` is a
sha256 over the concatenated event-id lines. Mirrors
`turtle-agentd._close_reasoning_run`:

```json
{
  "id": "urn:srcos:receipt:reasoning:c3e0…",
  "type": "ReasoningReceipt",
  "specVersion": "2.0.0",
  "runRef": "urn:srcos:reasoning-run:9f2c…",
  "taskRef": "urn:srcos:reasoning-task:9f2c…",
  "status": "completed",
  "traceHash": "sha256:…",
  "replayClass": "non-replayable-side-effect",
  "capturedAt": "2026-06-21T18:05:00Z"
}
```

**Replay-class derivation.** The session receipt's `replayClass` is the
*weakest* class of any action in the session:

- `exact` — the whole session was deterministic reads/navigation on static
  pages (navigate, read-dom, query-selector, extract-text, scroll, wait).
- `best-effort` — included render-timing-sensitive reads (screenshot, click,
  fill-form-field).
- `non-replayable-side-effect` — included any gated outbound mutation
  (submit-form, file-download, oauth-grant, payment-autofill, cross-origin-post,
  clipboard-write).
- `evidence-only` — included sensor reads (geolocation, camera-mic) that cannot
  be reproduced.

`replayClass ∈ {exact, best-effort, evidence-only, non-replayable-side-effect}`
per the schema enum.

---

## 3. Mapping table: agent intent → action → policy class → replayClass → eventType

| Agent intent                         | BearBrowser action  | Policy class | replayClass                   | eventType                  |
|--------------------------------------|---------------------|--------------|-------------------------------|----------------------------|
| "go to a page"                       | navigate            | allowed      | exact                         | `browser.navigate`         |
| "read the page"                      | read-dom            | allowed      | exact                         | `browser.read-dom`         |
| "find an element"                    | query-selector      | allowed      | exact                         | `browser.query-selector`   |
| "get the text of X"                  | extract-text        | allowed      | exact                         | `browser.extract-text`     |
| "take a screenshot"                  | screenshot          | allowed      | best-effort                   | `browser.screenshot`       |
| "scroll down"                        | scroll              | allowed      | exact                         | `browser.scroll`           |
| "wait for X"                         | wait                | allowed      | exact                         | `browser.wait`             |
| "click this link/button"            | click               | allowed*     | best-effort                   | `browser.click`            |
| "type X into the search box"         | fill-form-field     | allowed*     | best-effort                   | `browser.fill-form-field`  |
| "submit this form"                   | submit-form         | **gated**    | non-replayable-side-effect    | `browser.submit-form`      |
| "download this file"                 | file-download       | **gated**    | non-replayable-side-effect    | `browser.file-download`    |
| "authorize this app"                 | oauth-grant         | **gated**    | non-replayable-side-effect    | `browser.oauth-grant`      |
| "pay with my saved card"             | payment-autofill    | **gated**    | non-replayable-side-effect    | `browser.payment-autofill` |
| "send this to another site"          | cross-origin-post   | **gated**    | non-replayable-side-effect    | `browser.cross-origin-post`|
| "copy this to clipboard"             | clipboard-write     | **gated**    | non-replayable-side-effect    | `browser.clipboard-write`  |
| "share my location"                  | geolocation         | **gated**    | evidence-only                 | `browser.geolocation`      |
| "use the camera/mic"                 | camera-mic          | **gated**    | evidence-only                 | `browser.camera-mic`       |
| "log in for me"                      | enter-credentials   | **prohibited** | n/a (denied)                | `browser.policy.violation` |
| "type my card number"                | enter-payment-details | **prohibited** | n/a (denied)              | `browser.policy.violation` |
| "enter my SSN/passport"              | enter-government-id | **prohibited** | n/a (denied)                | `browser.policy.violation` |
| "change the sharing settings"        | modify-access-controls | **prohibited** | n/a (denied)             | `browser.policy.violation` |
| "solve the CAPTCHA"                  | bypass-captcha      | **prohibited** | n/a (denied)                | `browser.policy.violation` |
| "buy/transfer/place the order"       | execute-trade-or-transfer | **prohibited** | n/a (denied)          | `browser.policy.violation` |

\* `click` and `fill-form-field` are allowed in their read-shaped form. A click
the planner classifies as a form submission, or a fill into a credential /
payment / government-ID field, is reclassified — to the gated `submit-form` or
the prohibited `enter-*` actions respectively — per the `PolicyCondition`s in the
contract.

---

## 4. Where evidence lands

The bridge writes events to the append-only local buffer
(`/run/sourceos/provenance`, the `provenance` mount) before ingestion. Sinks:

- `eventSink: AgentPlane` — the reasoning-event stream.
- `policyDecisionSink: PolicyFabric` — permit/deny decisions.
- `workspaceVisibilitySink: ProphetWorkspace` — session visibility.

Event field shapes are also documented in `docs/provenance-events.md`; the
reasoning-family objects here are the canonical, spec-typed superset.

---

## 5. Unified fabric

Because the bridge emits the **same** `ReasoningRun` / `ReasoningEvent` /
`ReasoningReceipt` objects, at the **same** specVersion (`2.0.0`), with the
**same** URN prefixes, as `turtle-agentd`, a browser session and a terminal
agent session are replayable and auditable through one fabric. A reviewer reads
one event stream to reconstruct what the copilot did across the terminal and the
browser. That unification — spec-governed, evidence-emitting, replayable — is the
6–12 month gap no other browser closes.
