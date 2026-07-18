# BearBrowser: Superconscious ReasoningRun Traces in Browser Sidecar

## Purpose (issue BearBrowser #23)

Superconscious emits governed recursive reasoning artifacts. SourceOS reasoning contracts
are promoted into `SourceOS-Linux/sourceos-spec`. BearBrowser should display browser-agent
reasoning runs as a sidecar trace/evidence panel without exposing raw private reasoning content.

## Design

### Rendering surface

BearBrowser renders ReasoningRun traces in a collapsible sidecar panel on the right side of
the browser window. The panel is:

- Toggled with `Ctrl+Shift+R` or via the BearBrowser agent toolbar
- Displayed alongside the active page content (does NOT replace the page)
- Populated by the agent sidecar daemon, which watches the local reasoning artifact store
- Scoped to the current browsing session — no cross-session leakage

### Data format

The browser sidecar consumes the same JSONL format as TurtleTerm:

```jsonl
{"kind": "run-start", "run_ref": "urn:srcos:reasoning-run:sc:20260718T100000Z", "agent_ref": "...", "goal_ref": "...", "started_at": "..."}
{"kind": "step", "step_index": 0, "step_kind": "premise|inference|conclusion|fork", "confidence": 0.0–1.0, "suppress_mutation": true|false}
{"kind": "run-end", "outcome": "success|failure|suppressed", "confidence": 0.0–1.0, "receipt_ref": "..."}
{"kind": "fault", "fault_class": "...", "severity": "fatal|non-fatal", "suppress_mutation": true}
```

### Example trace (browser context)

```jsonl
{"kind": "run-start", "run_ref": "urn:srcos:reasoning-run:sc:20260718T100000Z", "agent_ref": "urn:srcos:agent:superconscious:2026", "goal_ref": "urn:srcos:goal:page-analysis:20260718", "browser_session_ref": "urn:srcos:browser-session:20260718T095900Z", "started_at": "2026-07-18T10:00:00Z"}
{"kind": "step", "step_index": 0, "step_kind": "premise", "confidence": 0.95, "suppress_mutation": false}
{"kind": "step", "step_index": 1, "step_kind": "inference", "confidence": 0.89, "suppress_mutation": false}
{"kind": "step", "step_index": 2, "step_kind": "conclusion", "confidence": 0.86, "suppress_mutation": false, "policy_decision_ref": "urn:srcos:policy-decision:sc-browser-mutation-admit-20260718"}
{"kind": "run-end", "outcome": "success", "confidence": 0.86, "receipt_ref": "urn:srcos:receipt:sc:20260718T100012Z"}
```

### Sidecar panel layout

```
┌─────────────────────────────────────────┐
│ Agent Reasoning   [−] [↗]               │
│ Run: …sc:20260718T100000Z               │
│ Goal: page-analysis                     │
├─────────────────────────────────────────┤
│ Step  Kind        Conf    Suppress       │
│  0    premise     0.95    ✗              │
│  1    inference   0.89    ✗              │
│  2    conclusion  0.86    ✗              │
├─────────────────────────────────────────┤
│ Outcome: success   Confidence: 0.86     │
│ Receipt: ↗                              │
└─────────────────────────────────────────┘
```

- `suppress_mutation=true` steps show an amber shield icon
- `fault` entries show in red with the fault class and severity
- Confidence < 0.70 shows a yellow warning indicator
- `run-end.receipt_ref` renders as a clickable link to the agentplane evidence record
- Raw step content (premises, conclusions) is NEVER shown — only kind, confidence, and suppress flag

## Integration boundary

- BearBrowser reads JSONL from the local path provided by the agent sidecar
- The agent sidecar writes JSONL delivered by AgentPlane for the current browser session
- Superconscious is the sole authority for producing ReasoningRun artifacts
- BearBrowser never has access to raw step content — the JSONL schema enforces this by design

## Rendering implementation

The sidecar panel is a Firefox WebExtension rendered in a sidebar context.

### Browser-extension message flow

```
AgentPlane
  → agent-sidecar (local daemon)
    → writes JSONL to ~/.local/share/bearbrowser/reasoning/<session-id>.jsonl
      → agent-sidecar extension reads via nativeMessaging
        → renders in sidebar panel via WebExtension API
```

The native messaging host is declared in `agent-sidecar/contract.yaml`. The sidebar extension
sources are in `agent-sidecar/`. Full implementation is gated on the AgentPlane delivery
path being live.

## Current implementation status

- JSONL format: specified above (aligned with TurtleTerm format)
- Sidecar panel: stub — rendering is documented but the extension is not yet fully wired
- Native messaging: stub — `agent-sidecar/contract.yaml` declares the interface
- AgentPlane delivery: pending AgentPlane integration

Tracking: issue BearBrowser #23.

## Related

- `docs/architecture.md` — BearBrowser architecture overview
- `docs/agent-harness-browser-receipts.md` — browser receipt capture contract
- `agent-sidecar/contract.yaml` — native messaging contract
- `sourceos-spec/SourceOS-Linux` — ReasoningAssay, ValidatorReceipt schemas
- TurtleTerm `docs/sourceos/REASONING_RUN_TASK_TREE.md` — same format, TurtleTerm rendering
