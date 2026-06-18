# T3 — Implementation Plan / Runbook (font + text-metric uniformity)

Companion to `anti-fingerprint-T3-fonts-text-metrics.md` (the *why*). This is the
*how* — the no-holes execution plan. Authored ahead of build; the compile/
integrate/ship steps happen on the build pipeline.

Guiding rule: **fix it once at the lowest shared layer, not N times at each JS
API.** Every text-metric API is a *consumer* of one thing — the per-glyph advances
the shaper produces. Patch that, and canvas / layout / SVG / Range all inherit the
uniform value. Patching each API is whack-a-mole and *will* leave holes.

## 1. Complete readback surface (the holes register)

Measured (Gecko 141, our RFP profile). Every row must end up uniform/quantized or
it is a hole.

| Surface | Path | Measured now | Covered by |
|---------|------|--------------|------------|
| `CanvasRenderingContext2D.measureText` (+ all `TextMetrics` fields) | canvas → gfxTextRun | 453.549987… subpixel, RFP-noop | W4 chokepoint |
| `Element.getBoundingClientRect` / `getClientRects` | layout → gfxTextRun | 453.549987… subpixel, RFP-noop | W4 |
| `Range.getBoundingClientRect` / `getClientRects` | layout → gfxTextRun | 453.549987… subpixel, RFP-noop | W4 |
| `Element.offsetWidth/Height`, `scrollWidth/Height`, `clientWidth/Height` | layout | 454 integer, but carries metric | W4 (uniform advances → uniform box) |
| `getComputedStyle().width` etc. (resolved px) | layout | depends on box | W4 |
| `SVGTextContentElement.getComputedTextLength` / `getSubStringLength` / `getExtentOfChar` / `getStart/EndPositionOfChar` / `getRotationOfChar` | SVG text → gfxTextRun | 439.600006… subpixel, RFP-noop | W4 |
| Font enumeration via `measureText` width deltas | font list | 13/14 macOS fonts, RFP-noop | W1+W2 |
| `document.fonts.check()` / `FontFaceSet`, `@font-face local()` | font list | system fonts reachable | W2 |
| Emoji / CJK glyph raster (tofu differences) | font list | OS-dependent | W1 (bundle Noto+emoji) |
| Audio `OfflineAudioContext` (related residual) | WebAudio | stable, RFP-noop | W6 |

Note the two metric paths produce *different* numbers (canvas 453.55 vs SVG
439.60) — proof a single-API fix is insufficient and the chokepoint must sit below
both, at the glyph advance.

## 2. Architecture — the single chokepoint

Gecko text flow (verify exact symbols against the build source):

```
HarfBuzz shape  →  gfxFont::ShapeText fills gfxShapedWord/gfxShapedText
                   with per-glyph advances (incl. GPOS kerning)
                        │
        ┌───────────────┼────────────────┬───────────────┐
   canvas measureText   nsTextFrame    SVGTextFrame    Range/BCR
   (gfxTextRun)        (layout)        (SVG)           (layout)
```

`gfxShapedText` per-glyph advance is the shared source. **W4 quantizes the advance
at the point shaping stores it** (`SetGlyphs`/`SetSimpleGlyph`/detailed-glyph
write), gated on `privacy.resistFingerprinting`. Because every consumer reads from
gfxShapedText, all of §1's layout/SVG/canvas rows become uniform from one patch.

## 3. Work items

### W1 — Font bundle + packaging
- Vendor a metric-compatible set: **Arimo** (Arial-metric), **Tinos** (Times),
  **Cousine** (Courier) + **Noto Sans/Serif/Mono** (Unicode coverage) + **Noto
  Color Emoji**. License: Apache-2.0/OFL — record in `branding/`/licensing.
- Place in app bundle (`Contents/Resources/fonts/`); add a build step in the
  packaging path (`scripts/bearbrowser-overlay-binary.sh` /
  `apply-sourceos-overlays.sh`) that copies them and activates bundled fonts.
- Pref: `gfx.bundled-fonts.*` (verify exact name/level on build — treat as
  unverified, per the bootstrapAddress/http3 lessons).

### W2 — Font exclusivity (allowlist) — **source patch, load-bearing**
- `layout.css.font-visibility` is proven insufficient (1/2/3 all leak 13/14 macOS
  fonts). The real lever is the platform font list allowlist.
- Patch `gfxPlatformFontList` so that, when RFP/bundling is on, the registered
  family list is **only** the bundled families — system families are never added,
  so they are invisible to enumeration **and** `local()` fallback. (Gecko already
  has allowlist plumbing à la Tor; populate it with the bundled set and force the
  system list empty.)
- Verify: `non-base fonts` vector → `0/14`.

### W3 — Generic remap + prefs (lands WITH W1/W2, never before)
- `font.name.serif.x-western=Tinos`, `…sans-serif…=Arimo`, `…monospace…=Cousine`,
  plus `font.name-list.*` per script (Noto for CJK/Arabic/Hebrew/Cyrillic).
- `layout.css.font-visibility.* = 1`.
- **Gate:** these prefs are inert/harmful without the font files + allowlist —
  shipping them first makes `sans-serif` resolve to a missing Arimo and fall back
  unpredictably. Ship W1+W2+W3 as one atomic change.

### W4 — Advance quantizer at gfxShapedText — **the chokepoint patch**
- In the shaped-glyph write path, replace each glyph advance `adv` with a
  deterministic quantization, gated on RFP:
  - *T3b (minimum):* round to whole CSS px: `adv = round(adv / appUnitsPerCSSPixel)
    * appUnitsPerCSSPixel`.
  - *T3c (best, "our own kerning"):* derive from font units —
    `adv = round(hmtxAdvance * size / unitsPerEm) ...` combined with GPOS deltas,
    so the value is font-intrinsic and identical on every OS, independent of the
    platform rasterizer.
- Also quantize the `TextMetrics` bounding-box fields populated for canvas
  (`actual/font/emHeight*`) at the canvas measure path so they match.
- **Uniform, not randomized** — every session/user returns the same value.
  (Contrast canvas/audio, which randomize. Getting this backwards adds entropy.)
- Verify: `canvas text metric` and `layout text metric` vectors → `int`.

### W5 — Deterministic advance source (Layer B, esp. macOS)
- Ensure advances come from HarfBuzz/hmtx, not CoreText optical/tracking
  adjustments (which perturb advances per-platform). Disable CoreText advance
  tuning in `gfxMacFont` advance retrieval, or compute advances from the font
  tables directly. Without this, W4's input still varies pre-quantization on
  borderline-rounding glyphs.

### W6 — Audio randomization (fold in while patching nsRFPService)
- RFP randomizes canvas but not `OfflineAudioContext` (measured: stable). Add a
  per-session noise to the WebAudio output in `nsRFPService` (the Gecko-native
  version of what the WKWebView shield did). **Randomized** (unlike text metrics).
- Verify: `audio (oac)` vector → RANDOMIZED across sessions.

### W7 — Verification
- `measure-fingerprint.mjs` already tracks: `non-base fonts`→`0/14`,
  `canvas text metric`→`int`, `layout text metric`→`int`, `audio (oac)`→randomized.
- Add `BEARBROWSER_BIN` runs against the real build to also clear the `screen WxH`
  (letterboxing) residual that headless can't show.
- **Cross-OS proof:** run the same probe on a Linux CI runner; assert identical
  text metrics Mac vs Linux (the real test of W4/W5 uniformity).
- Lock all targets into `verify-gecko-rfp.mjs` once met.

## 4. Sequencing & gates
1. **W1+W2+W3 atomic** (fonts + allowlist + remap) → kills font enumeration and
   font-selection entropy. Per-platform uniform. `non-base fonts`→`0/14`.
2. **W4 (+W5)** → kills the metric readback transform. `*text metric`→`int`,
   cross-OS uniform.
3. **W6** → closes the audio residual.
4. **W7 on real binary** → clears `screen WxH`; full scorecard.

Gate: never ship W3 prefs without W1/W2 in the same change (broken generics).

## 5. Risk / holes register
| Risk | Hole it would leave | Mitigation |
|------|--------------------|-----------|
| Fix only `measureText` | layout + SVG still leak (different number) | W4 sits below all consumers |
| `local()` reaches system fonts | enumeration bypass | W2 allowlist (not just visibility pref) |
| CoreText optical advances | W4 input varies pre-round | W5 |
| Quantize → layout reflow | minor visual shift | metric-compatible fonts; integer round is uniform |
| Randomize text metrics by reflex | splits cohort, adds entropy | W4 is explicitly UNIFORM |
| CJK/emoji tofu | OS-dependent missing-glyph fingerprint | bundle Noto + emoji (W1) |
| Pref-name drift | silent no-op | verify every pref on-build (harness habit) |
| offsetWidth still differs | coarse metric leak | follows from uniform advances (W4) |

## 6. Rollback / safety
- All behaviour gated on `privacy.resistFingerprinting` (+ a `bearbrowser.fonts.
  bundled` master) so it can be disabled without a rebuild for debugging.
- Patches isolated in the LibreWolf patch set; revert = drop the patch + prefs.
- Keep the bundled fonts behind the same flag so a packaging issue degrades to
  stock behaviour rather than no-fonts.
