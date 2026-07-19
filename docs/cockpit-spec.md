# BearBrowser Cockpit — the Sovereign Life Control Plane

Status: design (build-once, not MVP). Owner: BearBrowser. Companion to
`docs/agent-control-bridge.md` and `policy/bearbrowser-contract.yaml`.

## 1. What it is

The BearBrowser **cockpit** is the default start surface of the browser and the
single, sovereign control plane for the user's digital *and* physical life:

- their **web** (governed agentic browsing + federated search),
- their **work & knowledge** (Agora, Noetica, memory-mesh),
- their **smart home / IoT estate** (lights, locks, climate, media, security,
  sensors),

…all behind **one governance engine** that inspects intent and enforces policy
*before* any action reaches the web or a device, and attests every decision to a
tamper-evident evidence fabric.

This is the thing no incumbent can copy on their existing base:

- Chrome / Safari / Edge have a new-tab page, not an **action fabric** — they
  cannot show you (or block) what an agent is about to do.
- Alexa / Google Home / HomeKit have device control, not a **browser** and not an
  **inspectable, per-action policy** the user owns.
- The agentic browsers Gartner told enterprises to **block** in Dec 2025 (Comet,
  Atlas, Dia, Copilot) cloud-surveil and act with *no enforceable intent*. The
  cockpit is the answer to "block AI browsers": **a governed one**, where the
  same enforcement that contains a prompt-injected `enter-credentials` contains a
  prompt-injected `unlock-door`.

## 2. The five surfaces (rooms, not tabs)

| Surface   | Content | Backed by |
|-----------|---------|-----------|
| **Home**  | Device grid (rooms + scenes), presence, energy, security state — the control panel | `iot-sidecar` (§5) |
| **Search**| Federated SearXNG, one input, receipt trail | SearXNG sidecar / hosted (§4) |
| **Work**  | Agora work + knowledge widgets | Agora (deployed read-only) |
| **Mind**  | Noetica cockpit + memory-mesh grants | Noetica surfaces |
| **Receipts** | Live tail of every browser + IoT decision the bridge made | Reasoning evidence fabric |

The **Receipts** surface is the trust differentiator: nothing else on the market
shows the user a running, signed log of every action their agents proposed and
what policy did about it.

## 3. Cockpit shell — Vue, shipped inside the .app, offline-first

**Base.** Fork `socioprophet-web/app-vue` (the real SPA — carries the Studio
design language + Carbon tokens). *Not* `client-vue` (mocked) and *not* the React
marketing shell. Product UI is Vue.

**Embedding — no network for the shell.** Built assets ship inside the app bundle
and load from a local origin, never HTTP:

- Primary: register a `resource://bearbrowser-cockpit/` (or `chrome://bearbrowser/content/cockpit/`)
  mapping in the branding/omni step so the cockpit has a stable internal origin
  with no file:// path leakage. (The overlay already has a precedent hook:
  `browser.newtab.url` currently points at
  `file:///Applications/BearBrowser.app/Contents/Resources/BearBrowser-start.html`.)
- The cockpit assets live at `BearBrowser.app/Contents/Resources/cockpit/` and are
  installed by the macOS packaging step (peer of `prepare-macos-app-bundle.sh`).
- A **service worker** caches all shell assets so the cockpit renders with zero
  network — the "airplane on the tarmac" case. All *data* comes from loopback
  sidecars, never from the shell's origin.

**Wiring (per profile `user.js` + `policies.json`).**
- `browser.newtab.url` → the cockpit internal URL (replaces `BearBrowser-start.html`).
- `browser.startup.homepage` → same URL; `browser.startup.page = 1` (homepage).
- Keep the existing hardening (`NewTabPage: false` policy governs the *activity
  stream* new tab; our cockpit is served as the explicit newtab URL).

**Isolation.** The cockpit origin gets a tight CSP: `default-src 'self'` + the
loopback sidecar origins only. It cannot reach the public web. It talks to
`127.0.0.1` sidecars over `fetch`/WS, nothing else.

## 4. Default search = the federated SearXNG we already run

One search bar, one engine, for both the URL bar and the cockpit Search surface.

- Ship an **OpenSearch descriptor** as a builtin engine via the `SearchEngines`
  policy in each profile's `policies.json` (today it defaults to DuckDuckGo).
  Set `Default` to **BearBrowser Search** (SearXNG).
- Endpoint resolution (sovereign-first):
  1. Local SearXNG sidecar at `http://127.0.0.1:<port>/search?q={searchTerms}`
     when running (fully private, no query leaves the device),
  2. else the sovereign hosted SearXNG (still ours; DDG datacenter-IP blocks are
     already solved there — see `project_sovereign_search_st014`, #478/#744).
- The cockpit Search widget hits the **same** endpoint and renders results with a
  receipt trail (which engines answered, what was filtered), so search is a
  first-class governed surface, not a redirect.

## 5. IoT / smart-home control plane — `iot-sidecar` (Rust)

New sibling to `agent-sidecar/` and `credential-broker/`. Built once, in Rust —
no throwaway MVP. See `iot-sidecar/README.md` for the crate.

**Transport.** Loopback-only (`127.0.0.1`) REST + WebSocket. Refuses to bind any
non-loopback address. The cockpit Vue app is the only client; nothing off-device
can reach it.

**Adapters (the `DeviceAdapter` trait — one shape, every protocol).** Matter is a
first-class adapter, not deferred:
- `homekit` — HomeKit pair-verify / local control
- `matter` — Matter/Thread via `matter-rs` (or `chip-tool` shell-out)
- `mdns_ssdp` — Bonjour + SSDP discovery
- `ha_bridge` — Home Assistant REST (covers the long tail + gives Matter for free)
- `mqtt` — MQTT auto-detect
- `mock` — hardware-free adapter for tests + demos

**State.** Local SQLite (`rusqlite`, bundled). Device catalog, capabilities,
last-known state, append-only event log. Never leaves the device.

**Credentials.** Delegated to the existing `credential-broker/` — one auth
surface, not two. The sidecar stores no device secrets.

## 6. Governance — the moat, extended to the physical world

Physical actions are governed by the **same engine** as browser actions.

- `policy/bearbrowser-contract.yaml` now carries `spec.iotActionContract`
  alongside `spec.agentActionContract`, with the same three classes:
  - **allowed** — read-only (`list-devices`, `read-state`, `get-capabilities`,
    `subscribe-events`, `query-history`).
  - **gated** — reversible physical effect, needs a per-action approval token
    (`toggle-power`, `set-brightness/color/thermostat/fan/cover`, `set-scene`,
    `play-media`, `set-volume`, `lock-door`, `arm-security`).
  - **prohibited** — safety/security-critical, denied unconditionally
    (`unlock-door`, `disarm-security`, `open-garage-door`, `disable-camera`,
    `disable-sensor`, `pair-device`, `add-user`, `factory-reset`,
    `firmware-update`).
- **The user-gesture rule.** A prohibited action is reclassified *down* to gated
  **only** when a `policyCondition` proves `actor == "user"` **and**
  `userGesture == true` — flags the cockpit UI sets on direct interaction and
  that an agent planner cannot forge. An injected/agent `unlock-door` matches no
  condition → stays prohibited → denied. A scene that *bundles* a prohibited
  action inherits prohibited.
- **One engine.** `scripts/agent-control-bridge.py --surface iot` classifies every
  device command through the same `evaluate_action` that governs the browser, and
  emits `iot.<action>` / `iot.policy.violation` ReasoningEvents into the same
  evidence fabric. The `iot-sidecar` gate module invokes this bridge as the
  authoritative decision on **every** command and fails closed on deny/error — so
  the Python containment proof covers the Rust path by construction.
- **Proof.** `scripts/tests/test_iot_injection_containment.py` — 20/20. The
  physical-world twin of `test_injection_containment.py` (79/79). Injected
  `unlock-door`/`disarm`/`garage`/`factory-reset` are **blocked at decision time
  and attested**, never merely logged after.

## 7. Trust boundaries (data flow)

```
 ┌──────────────────────────── BearBrowser.app (Gecko) ────────────────────────────┐
 │  Cockpit (Vue app-vue)  origin: resource://bearbrowser-cockpit  CSP: self+loopback │
 │        │  fetch / WS (127.0.0.1 only)                                              │
 │        ├───────────────► SearXNG sidecar / hosted   → federated search + receipts │
 │        ├───────────────► iot-sidecar (Rust, loopback)                             │
 │        │                    │  every command → gate                               │
 │        │                    ▼                                                      │
 │        │            agent-control-bridge.py --surface iot   (THE engine)          │
 │        │                    │  permit → adapter drives device                     │
 │        │                    │  deny   → device I/O never happens                  │
 │        │                    ▼                                                      │
 │        │            iot.<action> / iot.policy.violation → evidence fabric         │
 │        └───────────────► credential-broker (device secrets, never in sidecar)     │
 └───────────────────────────────────────────────────────────────────────────────────┘
        No off-device egress from the cockpit, sidecars, or the gate.
```

## 8. Build & wiring plan (concrete)

1. **Gecko binary.** Linux via `scripts/gcp-build-linux.sh` → GCS →
   `packaging/linux/binary-source.env`; macOS via `.github/workflows/nightly-dmg.yml`
   (macos-15). human-secure builds on `latest`/150.
2. **Cockpit assets.** Add a build step that compiles `app-vue` → static bundle →
   `Contents/Resources/cockpit/`, and a branding/omni hook that maps the internal
   origin. Register the service worker.
3. **Profile wiring.** Point `browser.newtab.url` + `browser.startup.homepage` at
   the cockpit origin in each profile's `user.js`; keep hardening intact.
4. **Search default.** Add the SearXNG OpenSearch descriptor + set `Default` in
   each profile's `policies.json`.
5. **iot-sidecar.** Ship the Rust binary alongside the app; launch it loopback on
   cockpit start; register adapters. Gate wired to `--surface iot`.
6. **Governance (done).** `iotActionContract` + namespace-aware bridge +
   containment test all green.

## 9. Open decisions

- **Cockpit origin scheme:** `resource://` vs `chrome://` custom protocol — pick
  the one that survives Gecko updates with least patch surface.
- **Sidecar lifecycle:** launched by the browser process vs a user LaunchAgent —
  affects offline-at-boot behavior.
- **Matter transport:** `matter-rs` (pure Rust, heavier) vs `chip-tool` shell-out
  (faster to ship, external dep). Both sit behind the same `DeviceAdapter`.
