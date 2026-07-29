# Next session — pick up here

Written 2026-07-29 at the end of a long session, deliberately, so tomorrow does
not start by re-deriving context. Read this first.

## State of the world

- **22 PRs merged today (#104–#127).** Hardening, diagnostics, audit tooling, the
  RemoteSettings mirror. All of it is on `main`.
- **Builds running** on `f09b20d` (DMG / Linux / Windows). Nothing in those 22 PRs
  has been verified in a real binary yet. That is the single biggest gap.
- **Two self-inflicted build breaks today**, same root cause both times:
  I parse-checked instead of executing. (actors alpha-sort; then `global` vs
  `nonlocal` + a paren bug that would have written malformed prefs.)
  **Rule for tomorrow: run the code path against real input and validate the
  OUTPUT. A syntax check is not a test.**

## 🔴 P0 — verify the builds (blocks everything else)

The moment the three lanes finish:

    node scripts/audit/surface-audit-server.mjs &
    open -n /Applications/BearBrowser.app --args -no-remote \
      -profile /tmp/bb-verify "http://127.0.0.1:8099/"

Acceptance — all four must hold or the build is not done:
1. **No** `Missing chrome or resource URL: …bearblocker…` → ad-blocker loads its lists (#105)
2. **No** `detectportal.firefox.com` → phone-home lockdown + BearWall live (#107/#119)
3. WebGPU / WebMIDI / SpeechSynthesis / Notification / Push all `false`; GPC `true`;
   `RTCPeerConnection` gone (#109/#122)
4. **`hardwareConcurrency` == 2** — explicitly UNVERIFIED; the clamp rides
   BearTrapChild and has never run in a browser (#112)

Also confirm a crash now produces a local minidump (#110) and that
`about:crashes` lists it.

## 🔴 P0 — the thing that was picked and never done

**PR #77 — bake the cockpit into the browser.** Michael chose this explicitly
("1 2, 3") and it was never started. Spec is in that PR's
`docs/cockpit-browser-integration-handoff.md`; it is 4 pieces of browser-side glue
and pieces 1/2/4 map exactly onto mechanics already proven by BearNet:

1. **Stage** `assemble-cockpit.sh` output into the app —
   `Contents/Resources/{cockpit, sidecars/bearbrowser-agent-machine-bin, scripts, policy}`.
   Mirror `scripts/stage-bearnet.sh`; it already does this shape for BearNet.
2. **`resource://bearbrowser-cockpit/` substitution** in the autoconfig — copy the
   `resource://bearstart/` block verbatim; that pattern is verified working.
3. **Launch the sidecars** — gate `:8080`, agent-machine `:8091`, receipts `:8092`,
   via `Subprocess.call` exactly like the capture sidecar. ⚠️ Riskiest piece; the
   host must inject live ports into `runtime/cockpit-config.js` at launch.
4. **Point new-tab/homepage** at the cockpit (`AboutNewTab.newTabURL`) — one line,
   same as bearstart.

Topology to preserve: cockpit → gate (127.0.0.1:8080) → agent-machine/receipts.
Loopback only, no egress.

## P1 — regression protection (recommended twice, never built)

Wire `scripts/audit/` into the nightly workflows as a **post-build gate**: fail the
build if a hardened surface reopens. This would have caught the dead ad-blocker.
Without it, all 22 PRs can silently regress.

## P1 — we only ever measured macOS

Every number in this session is macOS. Run the audit against the Linux tarball and
the Windows build. WebGPU, `hardwareConcurrency`, BearWall behaviour on those
platforms is **unknown**, not "fine".

## P2 — finish what was started

- **Host the RS mirror.** `sync.mjs` + `review.mjs` work and are verified against
  Mozilla PROD, but nothing is served and `services.settings.server` still points
  upstream. Sequence: host → verify signature validation against the mirror →
  repoint → re-run the audit.
- **`extensions.update.url`** — same mirror treatment; documented, never done.
- **Rip newtab modules** — `AdsFeed`, `DiscoveryStreamFeed`,
  `InferredPersonalizationFeed`, `NewTabContentPing` are pref-muted but still ship.
  Deleting them breaks `ActivityStream.sys.mjs` imports, so it needs a build to
  test. Do it right after P0 verification, when a build loop exists.
- **BearTrap in-browser proof** — the honeypot has 26/26 node tests and has never
  been observed firing in a real browser. Load a fingerprinting page, watch
  `/honeypot`.
- **Vendor-traffic honeypot** — Michael asked to *honeypot* Mozilla/Google, and I
  built a **denylist** (BearWall blocks + reports). Blocking ≠ instrumenting.
  Consider a mode that lets a vendor callback reach a local sink so we can see what
  it *would* have sent.

## Blocked on Michael (do not re-litigate)

- **Code signing** — no paid certs by explicit choice. Builds ship unsigned.
- **`CHOCO_API_KEY`** — Chocolatey CI is wired and no-ops until the secret exists.
- **winget** — PR microsoft/winget-pkgs#409174 is in the moderator queue.

## Two deliberate privacy-vs-security holds

Both were surfaced rather than decided silently; the mirror is the answer to both,
once hosted:
- `services.settings.server` left alone — blanking it kills CRLite revocation.
- `extensions.update.*` left alone — blanking it freezes add-ons on vulnerable versions.
