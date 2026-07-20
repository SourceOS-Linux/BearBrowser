# Handoff — bake the sovereign cockpit *into* the browser

**Audience:** the BearBrowser agent. You have **not** been briefed on this; this doc is
the full context. **Companion:** `docs/cockpit-composition-plan.md`, `docs/cockpit-spec.md`.

## TL;DR

The SocioProphet **cockpit** + its sovereign backend (a bundled Noetica **agent-machine**)
now assemble and run as **one governed unit** — but **standalone** (a manual runner that
serves the UI to your default browser over `http://localhost`). Everything is merged.

**Your job:** move it from that scaffold into **BearBrowser.app itself**, so that opening
the browser shell *is* opening the cockpit — served on a **`resource://`** origin, with the
sidecars **launched by the browser on startup**, and **new-tab/homepage pointed at it**.
No localhost, no manual runner, no "point it at a page." This is exactly `cockpit-spec.md` §8.

The macOS `.app` build (the cbindgen `COUNT` blocker) is being fixed + a DMG is compiling —
so a real shell to wire into is imminent.

---

## What already landed — DO NOT rebuild

All merged to `main` across three repos. The composition is proven end-to-end.

| Piece | Where | What it is |
|---|---|---|
| Composition plan | `docs/cockpit-composition-plan.md` | the design of record |
| **Runtime resolver** | socioprophet #468 → `client-vue/src/config/cockpitRuntime.ts` | `resolveBase(key, envVar, fallback?)`, precedence **`window.__COCKPIT_CONFIG__` > `VITE_*` > fallback**. One client-vue bundle runs sovereign-embedded OR cloud-hosted. |
| **Cockpit build** | BB #70 → `scripts/build-cockpit.sh` | builds `client-vue` → a static bundle + injects `runtime/cockpit-config.js` as the first `<head>` script |
| **agent-machine sidecar** | BB #70 → `scripts/build-agent-machine-sidecar.sh` | `bun build --compile` of `@noetica/agent-machine` → one **68M self-contained binary** (loopback, offline-capable). Launcher: `scripts/bearbrowser-agent-machine` |
| **Governance gate (the moat)** | BB #71 → `scripts/bearbrowser-agent-machine-gate.py` | classifies every agent action via `agent-control-bridge.py` + `policy/bearbrowser-contract.yaml` (`spec.agentMachineActionContract`). Prohibited → 403 + attested. |
| **Receipts (trust ledger)** | BB #72 → `scripts/bearbrowser-receipts.py` | reads the shared reasoning evidence stream; unifies `browser.*`/`iot.*`/`agent.*` |
| **Assemble + orchestrate** | BB #73 → `scripts/assemble-cockpit.sh`, `scripts/bearbrowser-cockpit-up` | build+stage the whole app; stand it up governed |
| **Brew CLIs** | BB #74 → `packaging/homebrew/Formula/bearbrowser.rb` | `bearbrowser-cockpit-assemble`, `bearbrowser-cockpit-up` |
| Clean-box fixes | BB #75, #76 | bun (client-vue is **pnpm**) + writable work dirs; `cockpit-up` serves UI + opens a browser (the scaffold you're replacing) |

**Proven:** a full fresh-clone `assemble` → the cockpit renders **sovereign** (`mode: sovereign`,
agent calls → the gate, **no login wall**, 0 errors); the gate governs (a `POST /api/shell/exec`
→ **403**); receipts serve 200. Containment tests: browser 79/79, iot 20/20, agent-machine 28/28.

## The topology — keep it exactly

```
cockpit (resource://bearbrowser-cockpit)
   │  fetch  (window.__COCKPIT_CONFIG__ points every agent base at the GATE)
   ▼
gate  127.0.0.1:8080   ── classify (agent-control-bridge, sovereign) ──►  agent-machine sidecar  127.0.0.1:8091
                                                                          receipts  127.0.0.1:8092
```

Loopback only, no off-device egress. `runtime/cockpit-config.js` sets
`window.__COCKPIT_CONFIG__ = { mode:'sovereign', bases:{ agentMachine/hellgraph/studio → the gate } }`
**before** the app bundle; the client-vue resolver reads it. The host **writes the live sidecar
port** into that file at launch (the "inject the ports" step — `cockpit-up` does this today with `sed`).

---

## Your work — 4 pieces of browser-side glue (spec §8)

1. **Ship the assemble output into the `.app`.** The DMG build runs `scripts/assemble-cockpit.sh`
   (or stages its output) so the bundle contains
   `Contents/Resources/{cockpit, sidecars/bearbrowser-agent-machine-bin, scripts, policy}`.
   `assemble-cockpit.sh` already produces exactly this layout + a manifest.

2. **Register the `resource://bearbrowser-cockpit/` origin** → `Contents/Resources/cockpit/`
   (Gecko resource/chrome manifest). **This REPLACES** the standalone http static-serve
   (`cockpit-up`'s `python -m http.server`) — `resource://` serves the files natively. CSP =
   `self` + loopback (spec §7). Decide `resource://` vs a `chrome://` custom protocol (spec §9 open decision).

3. **Launch the sidecars on browser startup** from the native shell (`native/macos/*`).
   Reuse `bearbrowser-cockpit-up`'s sequence — **sidecar :8091 → gate :8080 → receipts :8092 +
   write the ports into `cockpit-config.js`** — but **drop** its http-serve + `open` browser steps
   (the browser renders `resource://` itself). Spawn on start, tear down on exit. The Rust
   `iot-sidecar` + the Python resolution sidecar already follow this loopback-sidecar pattern; mirror it.

4. **Point new-tab / homepage at the cockpit** — `browser.newtab.url` +
   `browser.startup.homepage` → the cockpit origin in each profile's `user.js`
   (`settings/profiles/*/user.js`), keeping the hardening intact. So opening the browser = the cockpit.

---

## Boundaries & gotchas (learned the hard way)

- **Noetica `@noetica/agent-machine` (`~/dev/noetica`) is PACKAGE-ONLY — never edit the engine.**
  `bun --compile` compiles it; don't touch internals. (Separate lane.)
- **client-vue is a pnpm project** (`pnpm-lock.yaml`, no `package-lock.json`) → build with **bun**, not `npm ci`.
- **The cockpit's sovereign mode already skips login** (no cloud auth needed) — verified; don't add an auth wall for local.
- **Ports** 8080/8091/8092 loopback; the gate has `Access-Control-Allow-Origin: *` so loopback fetches work from the `resource://` origin.
- **Capability tiering:** in sovereign mode the local agent-machine serves graph + agent surfaces; reasoner/ER/IE/algo/sherlock are **cloud-only** and degrade gracefully offline (by design — not a bug).
- **Read-only Cellar** bit us: build scripts now default their work dirs to `TMPDIR`. Inside the `.app`, `Contents/Resources` is read-only at runtime too — the assemble happens at **build/package time**, not first-run.
- **Tap auto-promote gap** (unrelated but noted): `homebrew.yml` only validates the formula; nothing runs `promote-to-tap.sh`, so the tap goes stale after merges. Worth automating.

## Definition of done

Open **BearBrowser.app** → a new tab renders the cockpit **natively** at
`resource://bearbrowser-cockpit/`; the sidecars are up (gate `/api/status` 200); a prohibited
agent action → **403** (the moat holds); receipts tick. **No localhost, no manual runner.**
