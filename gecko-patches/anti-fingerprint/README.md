# Anti-fingerprint Gecko patches (SourceOS overlay)

Gecko source patches for the BearBrowser anti-fingerprint track (tranche T3).
Authored against **Firefox 150.0.1** source (`firefox-150.0.1.source.tar.xz`),
following the existing in-tree pattern (`patches/fpp-canvas-fix.patch`).

## Wiring into the build
Each patch is a `patch -p1` unified diff. Integration is **automatic and
mirror-safe**: `scripts/apply-sourceos-overlays.sh` copies these into the
transient build-workspace clone and appends them to `assets/patches.txt`
(canvas before audio), so `bearbrowser-patches.py` applies them during the build.
The patches live canonically HERE in the overlay — never committed to the
read-only `librewolf-source-mirror`.

**Verified (2026-06-18):** `check-patchfail.sh` applied the **full upstream patch
sequence (~40 LibreWolf patches) + both of ours** to a fresh Firefox 150.0.1
extraction with **zero rejects** — "All patches were applied successfully." So
these are no longer just "applies to pristine"; they apply in the real build
order (the `fpp-canvas-fix.patch` co-location on CanvasRenderingContext2D.cpp /
nsRFPService.cpp is handled by patch offset detection). Remaining gate: `./mach
build` (compile) on a capable runner / the Forgejo pipeline.

## Patches

### `anti-fp-canvas-text-metrics.patch` — status: APPLIES CLEANLY, compile-pending
Covers the **canvas** text-metric readback (the first W4 call site).

- Adds `RFPTarget::CanvasTextMetrics` (id 81) to `RFPTargets.inc`.
- In `CanvasRenderingContext2D::DrawOrMeasureText` (the `MEASURE` branch),
  gates on `nsContentUtils::ShouldResistFingerprinting(doc, RFPTarget::
  CanvasTextMetrics)` and quantizes **every** `TextMetrics` field (`width`,
  `actualBoundingBox*`, `fontBoundingBox*`, `emHeight*`, baselines) to whole CSS
  px via `std::round`. **Uniform, never randomized** (randomizing text metrics
  would split the RFP cohort — see the T3 spec).

Verified: applies and reverses cleanly against pristine Firefox 150.0.1
(`patch -p1 --dry-run` + reverse). Grounded APIs confirmed present in-tree:
the `(const Document*, RFPTarget)` `ShouldResistFingerprinting` overload,
`std::round` (already used in the file), `nsContentUtils.h`/`nsRFPService.h`
includes. **Not yet compiled** — `./mach build` is the remaining gate.

Flips harness vector `canvas text metric` → `int`. Does NOT cover the layout
(`getBoundingClientRect`/`Range`) or SVG (`getComputedTextLength`) paths — those
are separate call sites (see the T3 implementation plan, §W4) and remain TODO.

### `anti-fp-audio.patch` — status: APPLIES CLEANLY, compile-pending (W6)
Closes the audio fingerprint residual — the one vector where Brave currently beats
us. RFP randomizes canvas but **not** WebAudio, so the OfflineAudioContext hash is
stable across sessions (measured). This adds a per-session, inaudible (±1e-7
multiplicative) farble to the audio sample data so the hash is unlinkable across
sessions, gated on the new `RFPTarget::WebAudioFarble`.

Touches 5 files: adds the RFPTarget, an `nsRFPService::FarbleAudioData()` helper
(modeled on `RandomizePixels`, per-session static factor from `RandomUint64`), and
calls it from the read paths — `AudioBuffer::RestoreJSChannelData` (the single
materialization point feeding `getChannelData`/`copyFromChannel`) and
`AnalyserNode::GetFloat{Frequency,TimeDomain}Data`. Byte variants are skipped
(quantized to 0–255, a 1e-7 farble is a no-op there — not a hole). **Uniform-noise
caveat:** per-session (per-process), not yet per-origin like Brave — defeats
cross-session linkage (the measured residual); per-origin is a follow-up.

Verified: applies + reverses cleanly on pristine Firefox 150.0.1, **and sequences
cleanly after `anti-fp-canvas-text-metrics.patch`** (both edit `RFPTargets.inc` at
non-overlapping locations). Forward-declares `nsIGlobalObject` in nsRFPService.h.
**Not yet compiled.** Flips harness vector `audio (oac)` → randomized on the real
build.

### Patch order (assets/patches.txt)
Register in this order; they're independent but verified to apply in sequence:
1. `anti-fp-canvas-text-metrics.patch`
2. `anti-fp-audio.patch`

### Remaining TODO
- `anti-fp-layout-text-metrics.patch` (Element/Range BCR via nsLayoutUtils)
- `anti-fp-svg-text-metrics.patch` (SVGTextContentElement::*)
- W2 font allowlist is shipped as **prefs** (`font.system.whitelist` + bundle), not
  a patch — see `packaging/bundled-fonts/`.
