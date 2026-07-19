# Cockpit Composition Plan — BearBrowser × Noetica agent-machine × client-vue

Status: **plan** (decisions locked 2026-07-19). Companion to `docs/cockpit-spec.md`;
this doc records the deltas that make the cockpit *robust and modular* across the
sovereign-local and connected-cloud surfaces.

## Goal

One cockpit that runs identically in three places, composed from independent,
swappable pieces:

- **BearBrowser-embedded** — offline-first, sovereign, talks to loopback sidecars.
- **prophet-platform-hosted** (`app.socioprophet.ai` on GKE) — the shared/collaborative plane.
- **Firebase** (`app.socioprophet.com`) — today a backend-less shell; becomes useful once it's config-driven (see Lane 1).

## Decisions locked

1. **Embedded cockpit = `client-vue`** — supersedes `cockpit-spec.md §3/§7/§8`, which
   said "fork `app-vue`, *not* `client-vue` (mocked)." That reasoning is stale:
   `client-vue` is now the **canonical, real** cockpit (54 surfaces, live `/svc`
   backends, shipped to GKE via prophet-platform #882). One codebase, three surfaces.
2. **Runtime model = local-first, cloud opt-in** — extends the spec's sovereign-only
   "no off-device egress" (§7). The sovereign loopback path stays the **default**;
   registering/signing in **adds** an opt-in cloud plane for the shared surfaces.
   Unregistered + offline is a complete, self-sufficient control plane.

## The three composable pieces

| Piece | Role | Ships as |
|---|---|---|
| `client-vue` cockpit | the UI, offline-first | static bundle at `Contents/Resources/cockpit/`, `resource://bearbrowser-cockpit/` origin |
| `@noetica/agent-machine` | the local sovereign brain (`/api/*`) | **loopback sidecar** (`127.0.0.1`, ephemeral-or-`:8080`), launched like `bearbrowser-sidecar-server` |
| endpoint **resolver** | the local↔connected switch | a runtime-config module inside `client-vue` (Lane 1) |

## The modular heart — runtime config, not build-time env

Today `client-vue` services resolve their base at **build time**:
`const BASE = import.meta.env.VITE_X_BASE ?? '/svc/x'`. One build = one target. That's
why the same bundle is a working cockpit on GKE but a dead shell on Firebase, and why
it can't also be the sovereign embed.

**Fix:** resolve endpoints at **runtime** from a single `cockpitConfig`, host-injected,
with a sovereign-loopback fallback. One bundle then runs everywhere:

```
// resolved once at boot; host injects window.__COCKPIT_CONFIG__ (optional)
cockpitConfig = {
  mode: 'sovereign' | 'connected',
  bases: {
    agentMachine: 'http://127.0.0.1:<port>',   // BearBrowser injects the sidecar port
    studio:       '/svc/studio' | 'http://127.0.0.1:<port>',
    hellgraph:    '/svc/hellgraph',
    search:       'http://127.0.0.1:<port>' | 'https://search-api.socioprophet.ai',
    // …one entry per service client
  }
}
```

- **Sovereign default** (embedded / unregistered): every base points at a **loopback
  sidecar**; no host injection needed → falls back to `127.0.0.1` defaults. Matches
  the spec's "data only from `127.0.0.1`" trust boundary (§7).
- **Connected** (registered): the shared-plane bases repoint to `*.socioprophet.ai`
  (`app/api/studio/search-api`), populated on sign-in. Loopback stays available.
- **Host injects the config it's entitled to:** BearBrowser writes the loopback sidecar
  ports at the `resource://` origin; the GKE nginx (or a `/config.json`) serves the
  cloud bases. The cockpit itself is dumb about *where* it runs.

This is the single change that makes the cockpit modular. It also retroactively fixes
the Firebase shell (point it at the cloud bases) and keeps the GKE deploy working
(defaults already `/svc/*`).

## agent-machine as a loopback sidecar

`@noetica/agent-machine` (`~/dev/noetica/agent-machine`, `server.ts`, Node/tsx) is the
`/api/*` brain the cockpit already calls at `127.0.0.1:8080`. Bundle it like the
existing sidecars:

- A launcher `bearbrowser-agent-machine` mirroring `scripts/bearbrowser-sidecar-server.py`
  (loopback-only bind, ephemeral-or-`:8080`, session-token gated, refuses non-loopback).
- Packaged through the Homebrew/nix path alongside `bearbrowser-sidecar-server`.
- BearBrowser injects its chosen port into `cockpitConfig.bases.agentMachine`.
- **Governance stays one engine:** agent-machine actions route through the existing
  `scripts/agent-control-bridge.py` contract (the moat holds locally, per §6).

## Registration / connection detection

- **Local-first:** no registration required; every base is loopback; the cockpit is
  fully usable offline.
- **Registration = sign-in** (Firebase/socbase). On success the cockpit sets
  `cockpitConfig.mode='connected'` and populates the cloud bases. Purely opt-in;
  revocable (sign out → back to sovereign loopback).

## Build lanes (repo ownership + sequence)

1. **`client-vue` (socioprophet) — the resolver.** Replace the scattered
   `VITE_X ?? default` reads with a `cockpitConfig` resolver (runtime-injected →
   loopback fallback → cloud when connected). *THE modular heart; testable standalone;
   also un-breaks Firebase.* — platform/cockpit lane.
2. **BearBrowser — embed + inject + sidecar.** (a) packaging step: build `client-vue`
   → `Contents/Resources/cockpit/` on `resource://` (spec §8, currently unbuilt);
   (b) inject `window.__COCKPIT_CONFIG__` with sidecar ports at that origin;
   (c) `bearbrowser-agent-machine` loopback launcher + packaging; (d) update
   `cockpit-spec.md` §3/§7/§8 `app-vue`→`client-vue`. — BearBrowser lane.
3. **`@noetica/agent-machine` — portable bundle mode.** Ensure a loopback-bindable,
   session-token-gated start suitable for bundling (packaging only; **do not edit
   engine internals** — Noetica lane, coordinate).
4. **Governance wiring.** Route agent-machine actions through `agent-control-bridge`.

**Start with Lane 1** — it's the heart, it's in a repo we own and just shipped, it's
independently verifiable, and it immediately makes the hosted + Firebase cockpits
config-driven. Embed (Lane 2) and the agent-machine sidecar follow.

## Lane boundaries (do not cross)

- `client-vue` = platform/cockpit lane (ours).
- BearBrowser = its own repo/lane.
- agent-machine **engine** = Noetica lane — **run/package only, never edit internals**.
