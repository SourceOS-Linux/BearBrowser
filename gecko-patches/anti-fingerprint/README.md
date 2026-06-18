# Anti-fingerprint Gecko patches (SourceOS overlay)

Gecko source patches for the BearBrowser anti-fingerprint track (tranche T3).
Authored against **Firefox 150.0.1** source (`firefox-150.0.1.source.tar.xz`),
following the existing in-tree pattern (`patches/fpp-canvas-fix.patch`).

## Wiring into the build
Each patch is a `patch -p1` unified diff. To activate in the LibreWolf-style
build repo (the one with `scripts/bearbrowser-patches.py` + `assets/patches.txt`):

1. Copy the `.patch` into that repo's `patches/` dir.
2. Append its path to `assets/patches.txt` (applied in listed order).
3. `make check-patchfail` to confirm it applies, then `make build`.

(Or wire `apply-sourceos-overlays.sh` to copy these + append to `patches.txt`
automatically, so they live canonically here in the overlay.)

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
are separate call sites (see the T3 implementation plan, §W4) and remain TODO:
- `anti-fp-layout-text-metrics.patch` (Element/Range BCR via nsLayoutUtils) — TODO
- `anti-fp-svg-text-metrics.patch` (SVGTextContentElement::*) — TODO
- `anti-fp-font-allowlist.patch` (gfxPlatformFontList exclusivity, W2) — TODO
- `anti-fp-audio.patch` (nsRFPService OfflineAudioContext noise, W6) — TODO
