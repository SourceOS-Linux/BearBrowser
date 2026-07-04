# Fingerprint cohort-match hardening — 2026-06-30

Goal: make BearBrowser's tor-mode fingerprint **INDISTINGUISHABLE from the
Firefox-ESR / Tor-Browser cohort**. The research's sharpest caveat (Mullvad's
small-cohort problem): spoof-normality only works if we blend into a real crowd —
any surface that makes us STAND OUT (whether by leaking the real device value OR by
"over-hardening" to something no stock Tor/ESR browser emits) undoes the strategy.

The first tor-mode build scored **12/20 cohort-matching**. This pass fixes the
genuinely cohort-mismatched surfaces. **Re-measurement requires the next paid GCP
build** (`scripts/measure-fingerprint.mjs` against the real binary / Forgejo
`full-build`); the changes here are config-level, verified syntactically valid and
internally consistent, but the post-rebuild scorecard is the only true confirmation.

## Files changed
- `settings/profiles/tor-mode/user.js` — WebGL, plugins, audio/text cohort notes.
- `settings/profiles/human-secure/user.js` — plugins (RFP baseline tor-mode rides on).
- `profiles/default/user.js` — packaging-default shield reconciled to stock-RFP
  cohort posture (removed stale no-ops + hand-rolled spoofs that diverged from RFP).

---

## Leaking surfaces — root cause, fix, expected result

### 1. WebGL renderer = `no-webgl` + WebGL ext count = `undefined`  →  LEAKING
**Root cause.** Tor-mode set `webgl.enable-debug-renderer-info=false`. That removes
the `WEBGL_debug_renderer_info` extension, so `UNMASKED_RENDERER_WEBGL` is
unavailable and `getSupportedExtensions()` is missing an entry — the harness read
this as `no-webgl` / `ext count = undefined`. A browser that ships **no WebGL** (or
strips the debug extension) is RARE and distinctive — the opposite of blending in.
The `profiles/default/user.js` shield had the mirror-image problem: it hard-coded a
fixed fake renderer (`Intel Iris OpenGL Engine` / `Intel Inc.`) which is ALSO not
the cohort value and is inconsistent with RFP's own masking.

**Cohort fact.** Tor Browser / Firefox-ESR ship WebGL **enabled** with RFP masking
VENDOR / RENDERER / `UNMASKED_RENDERER_WEBGL` to a uniform cohort string and
returning the standardized RFP extension list. WebGL is *present-but-spoofed*, never
disabled, never hand-overridden.

**Fix.**
- tor-mode: removed `webgl.enable-debug-renderer-info=false`; set
  `webgl.disabled=false` + `webgl.enable-webgl2=true` explicitly so the profile can
  never sit in an inherited/disabled state. RFP masks the renderer.
- default shield: removed `webgl.renderer-string-override` /
  `webgl.vendor-string-override`; kept `webgl.disabled=false`. RFP owns the mask.

**Expected post-rebuild:** `WebGL renderer` → uniform RFP cohort string
(NORMALIZED/MATCHES-COHORT, no longer `no-webgl`); `WebGL ext count` → the
standardized RFP extension count (a real number, no longer `undefined`).

### 2. plugins = 5  →  LEAKING
**Root cause.** The bundled PDF viewer surfaced as 5 pseudo-plugin entries in
`navigator.plugins`. The scorecard's cohort predicate is `plugins.length === 0`.
**Cohort fact.** Firefox-ESR / Tor under RFP report an **empty** `navigator.plugins`
(length 0). 5 stands out.
**Fix.** Added `pdfjs.enableScripting=false` to tor-mode and human-secure so the
PDF.js pseudo-plugin scripting surface is not exposed; RFP standardizes the array to
empty. Nothing in our config INJECTS plugins — this just stops the PDF surface from
being enumerable.
**Expected post-rebuild:** `plugins` → 0 (MATCHES-COHORT).

### 3. audio (oac) = identical hash  →  flagged LEAKING (left at stock-RFP, by design)
**Root cause / cohort fact.** The scorecard's `noise` heuristic marks audio LEAKING
when `hardened == control`. In tor-mode our custom `WebAudioFarble` patch (RFPTarget
id 82) is **deliberately disabled** (via
`privacy.fingerprintingProtection.overrides=-WebAudioFarble`) and is **omitted from
the FF140-ESR tor-mode build** entirely. With it off, audio sits at **stock RFP** —
and stock RFP / Tor Browser **leave WebAudio a stable residual** (RFP randomizes
canvas readback but NOT WebAudio; see `gecko-patches/anti-fingerprint/README.md`
and `docs/best-in-world-rubric.md`). So in tor-mode a stable audio hash IS the
cohort-normal value. Enabling our farble here would make us a *tiny distinct cohort
riding Tor* — the cohort paradox.
**Decision.** Left untouched in tor-mode (documented in the profile). The harness'
`hardened==control` heuristic reads it as LEAKING, but flipping it to randomized
would BREAK cohort match. Our audio-farble edge stays active in **direct /
human-secure** mode, where it is a genuine improvement Tor lacks, not a leak.
**Expected post-rebuild:** unchanged in tor-mode (stays at stock-RFP = cohort);
this row is a heuristic false-positive for the Tor cohort, not a fixable mismatch
without de-blending. (If the grader is later taught the Tor cohort baseline, it
should reclassify to MATCHES-COHORT.)

### 4. canvas/layout text metric = subpixel  →  flagged LEAKING (left at stock-RFP)
**Same situation as audio.** Our `CanvasTextMetrics` patch (RFPTarget id 81)
quantizes measureText to integer — a novel edge Tor lacks. It is disabled in
tor-mode (`-CanvasTextMetrics`) and omitted from the FF140-ESR build. Stock RFP /
Tor Browser leave `measureText` **sub-pixel**, so `subpixel` IS the Tor cohort value
in tor-mode. Forcing `int` here would split the cohort. Left untouched; the
int-quantizer remains active in direct/human-secure mode.
**Expected post-rebuild:** unchanged in tor-mode (stays subpixel = cohort).

> Note on the grading tension (#3, #4): the scorecard's static `expect:'int'` /
> `noise` rules encode the **direct-mode best-in-world** target, where our patches
> ARE active. For **tor-mode** the correct target is the *Tor cohort* value
> (subpixel audio-stable), which our patches deliberately do not alter. These two
> rows are therefore not "leaks to fix" in tor-mode — they are correct cohort
> blending. They legitimately flip to int/randomized only in the direct build.

---

## Packaging-default shield (`profiles/default/user.js`) reconciliation
Stale no-ops removed and hand-rolled spoofs replaced with stock-RFP cohort posture:
- `canvas.poisondata` + `privacy.resistFingerprinting.randomDataOnCanvasExtract` —
  **removed** (no-ops since bug 1670447 / 1816189; RFP randomizes canvas itself).
- `webgl.renderer-string-override` / `vendor-string-override` — **removed** (fixed
  fake renderer ≠ cohort; RFP masks it). WebGL kept enabled.
- `general.useragent/platform/oscpu/appname/appversion.override` — **removed** (RFP
  ignores them; the stale rv:128 UA was an inconsistent-identity leak).
- `dom.maxHardwareConcurrency=4` — **removed** (RFP cohort = 2; 4 diverges).
- `font.system.whitelist=""` → **`"Arimo, Tinos, Cousine"`** + `gfx.bundled-fonts.
  activate=1` + generic font-family maps (empty whitelist = every OS font
  enumerable = the real font leak; aligned to the compiled-profile Croscore bundle).
- `browser.display.use_document_fonts=0` — **removed** (blocking web fonts is both
  site-breaking and a non-cohort behavior).
- `privacy.firstparty.isolate=true` (+ FPI sub-flags) — **removed**; replaced with
  dFPI (`privacy.partition.network_state` / `serviceWorkers`), the ESR/Tor cohort
  approach.
- `network.http.http3.enabled=false` — **removed** (misspelled → silent no-op; and
  we do not disable HTTP/3 in direct mode — that lives in tor-mode only).

---

## NOT touched (correct surfaces — do not "fix")
- **screen WxH 1200x500 / devicePixelRatio 2** — almost certainly **headless-VM
  Xvfb artifacts** of the build VM, NOT config bugs. RFP letterboxing handles the
  real window. **These need re-verification on a REAL (non-headless) run** before
  any config change — chasing them with prefs could break real installs.
- **canvas 2D = RANDOMIZED** — correct (stock RFP per-session noise = exactly Tor).
- All surfaces already scored MATCHES-COHORT — left as-is.

## Expected scorecard delta (next build)
| Surface | Before | Expected after |
|---|---|---|
| WebGL renderer | LEAKING (`no-webgl`) | MATCHES-COHORT / NORMALIZED (RFP mask) |
| WebGL ext count | LEAKING (`undefined`) | NORMALIZED (RFP ext list count) |
| plugins | LEAKING (5) | MATCHES-COHORT (0) |
| audio (oac) | LEAKING (heuristic) | unchanged — stock-RFP = Tor cohort (heuristic FP) |
| canvas/layout text metric | LEAKING (heuristic) | unchanged — stock-RFP subpixel = Tor cohort (heuristic FP) |
| screen / dpr | leaking? | re-verify on real run (likely VM artifact) |

Net expectation: **+3 genuine cohort flips** (WebGL renderer, WebGL ext count,
plugins) → roughly **15/20**, with audio + the two text-metric rows being correct
tor-mode cohort blending that the static grader over-flags, and screen/dpr pending a
non-headless re-measure. Only a rebuild + re-score confirms.
