# BearBrowser Agent Control Bridge

The evidence-emitting control-bridge specification: how TurtleTerm's copilot
drives BearBrowser's `agent-runtime` profile under the governance contract
(`policy/bearbrowser-contract.yaml`), with every action gated by policy and
attested by a replayable reasoning trace.

This is the moat. No other browser ships a spec-governed, evidence-emitting
agent automation surface. The contract + bridge are the differentiating IP and
are ready the moment the binary lands.

> **Honesty note — runtime binding is pending the binary build.**
> BearBrowser has no compiled binary yet (the LibreWolf compile lane is wired in
> `scripts/bearbrowser-build-binary.sh` but has not been run). The control
> endpoint described here is **not yet a live automation surface**. What is real
> and ready today is (1) this bridge spec, (2) the governance contract, and (3)
> the emission schema — which is **identical to TurtleTerm's** reasoning-event
> family, so the evidence fabric is already unified across the two products. The
> reference emitter is `TurtleTerm/assets/sourceos/bin/turtle-agentd`
> (`_open_reasoning_run`, `_emit_reasoning_event`, `_close_reasoning_run`); the
> browser bridge mirrors those exact shapes.

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
