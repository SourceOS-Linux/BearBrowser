# BearBrowser `agent-runtime` profile

The governed browser execution surface that TurtleTerm's copilot drives. This
profile is the agent-facing counterpart to `human-secure`. It is **deny by
default**, ephemeral, and every action it takes is policy-gated and attested.

> Runtime binding is pending the LibreWolf binary build. These files describe
> the intended posture; they are not yet active in a running browser process.

## Files

| File              | Role                                                                 |
|-------------------|----------------------------------------------------------------------|
| `user.js`         | Baseline agent-runtime prefs (downloads, sessionstore, sensor off).  |
| `user-overlay.js` | Agent-runtime overlay: enables the loopback BiDi control surface, suppresses automation-blocking prompts, re-asserts the shield. Applied on top of `user.js` and the 101-pref shield in `profiles/default/user.js`. |
| `policies.json`   | Enterprise policy keys (telemetry off, no studies, no Pocket, etc.). |

## Posture

- **Control surface:** WebDriver-BiDi (Gecko-native), loopback-only
  (`127.0.0.1`), ephemeral port, per-session token, **off by default** —
  opt-in per session. See `docs/agent-control-bridge.md`.
- **Fingerprinting:** spoof-normality. Inherits the full 101-pref shield;
  rides the Firefox-ESR cohort. `navigator.webdriver` is suppressed so the page
  cannot detect the agent. The overlay never weakens the shield.
- **Downloads:** gated + quarantined to `/workspace/downloads`; never
  auto-executed. See `mounts/agent-browser-mounts.yaml`.
- **Sensitive actions:** credentials, payment, government-ID entry are
  **prohibited**; form-submit, downloads, oauth, payment-autofill, clipboard,
  geolocation, camera/mic are **gated** (per-action approval). See the action
  classes in `policy/bearbrowser-contract.yaml`.
- **Evidence:** every action emits a conformant `ReasoningEvent`
  (specVersion `2.0.0`); sessions open a `ReasoningRun` and close with a
  `ReasoningReceipt`, identical to the `turtle-agentd` emitter so the fabric is
  unified.

## What the overlay sets (summary)

- `remote.active-protocols=1` (BiDi only), `remote.enabled=false` (per-session
  opt-in), `remote.force-local=true`, `marionette.port=0` (ephemeral).
- Suppresses `beforeunload`, popup, tab-close, crash-resume, and update prompts
  that block unattended automation.
- Pins downloads to `/workspace/downloads`; disables credential/autofill storage.
- Re-asserts `privacy.resistFingerprinting`, `privacy.firstparty.isolate`,
  timer-precision reduction, `dom.webdriver.enabled=false`, telemetry off.

## Governance authority

- Contract: `policy/bearbrowser-contract.yaml`
- Mount plan: `mounts/agent-browser-mounts.yaml`
- Bridge spec: `docs/agent-control-bridge.md`
- Canonical schemas: `sourceos-spec/schemas/` (Policy, Rule, Obligation,
  NetworkAccessProfile, ExecutionSurface, Reasoning* — `$id`s cited in the
  contract).
