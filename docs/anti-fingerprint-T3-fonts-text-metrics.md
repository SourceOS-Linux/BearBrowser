# T3 — Font & Text-Metric Uniformity (implementation spec)

Status: spec / not yet implemented. Owner: anti-fingerprint track.
Tranche: T3 (architecture — needs LibreWolf source patches + packaging, not just prefs).

## 1. Problem — two distinct vectors, both wide open

Bundling glyph *files* is necessary but **not sufficient**. There are two separate
fingerprint surfaces in text:

1. **Font enumeration** — "which fonts exist." Measured today (Gecko 141 + our RFP
   profile): **13 of 14 macOS system fonts still detectable** (Zapfino, Papyrus,
   Hoefler Text, Optima, …). `layout.css.font-visibility` = 1, 2, and 3 are
   *identical* — the pref does not hide OS-bundled fonts. No pref closes this.

2. **Text-metric / kerning readback** — "how text measures." A page renders a
   string and reads the exact transform back. Measured today:

   ```
   measureText("AVA To Wa Yo PAW fjffifl 9.9.9.9").width
     control (bare FF) = 453.54998779296875
     human-secure RFP  = 453.54998779296875   ← RFP does NOTHING to this
   actualBoundingBoxRight = 453.015625, ascent = 23.28125, descent = 6.75 …
   getBoundingClientRect().width = 453.54998779296875
   ```

   That single float encodes **font selection + shaper (HarfBuzz GPOS kerning) +
   platform rasterizer (CoreText / DirectWrite / FreeType)** at ~15 digits of
   sub-pixel precision. RFP leaves it fully exposed. This is the "huge fingerprint"
   — bundling fonts alone will *not* fix it, because the same font file still
   rasterizes to different advance widths on different platforms.

Harness vectors tracking these (in `scripts/measure-fingerprint.mjs`):
`non-base fonts` (target `0/14`) and `text-metric readback` (target `int`).
Both currently `LEAKING`.

## 2. Design — three layers (each strictly necessary)

### Layer A — Bundle fonts and make them exclusive
Goal: every user resolves `serif`/`sans-serif`/`monospace` to the **same** font,
and no system font is visible to enumeration *or* fallback.

- **Font set** (metric-compatible, broad coverage — the Tor/Mullvad lineage):
  - Arimo (Arial-metric), Tinos (Times-metric), Cousine (Courier-metric)
    — Croscore/Liberation, metric-compatible with the MS core fonts so existing
    site layouts don't reflow.
  - Noto Sans / Noto Serif / Noto Sans Mono for Unicode coverage (CJK, Cyrillic,
    Arabic, Hebrew, etc.) — prevents "tofu" (missing-glyph) differences, which are
    themselves a fingerprint.
  - One emoji font (Noto Color Emoji or Twemoji) so emoji raster is uniform.
- **Packaging:** ship the set in the app bundle (`Contents/Resources/fonts/`) and
  activate via `gfx.bundled-fonts` (verify exact pref/level on the target build —
  treat pref names as unverified until checked, per the bootstrapAddress/http3
  lessons).
- **Exclusivity (the load-bearing part — a source patch, not a pref):** restrict
  `gfxPlatformFontList` to the bundled allowlist so system fonts are invisible to
  both `local()` fallback and enumeration. This is Tor's approach; `font-visibility`
  alone is proven insufficient (§1). Without this patch, Layer A is cosmetic.
- **Generic remap (prefs):** point the CSS generics at the bundled fonts —
  `font.name.serif.x-western=Tinos`, `font.name.sans-serif.x-western=Arimo`,
  `font.name.monospace.x-western=Cousine`, and the matching `font.name-list.*`
  fallbacks for each script. Set `layout.css.font-visibility.* = 1`.

Outcome: font enumeration → `0/14`, and font *selection* entropy removed
(everyone's `sans-serif` is Arimo). Per-platform uniform.

### Layer B — Deterministic shaping & kerning
Goal: advance widths come from the **font's own tables** (hmtx + GPOS), computed
identically on every OS — not from the platform rasterizer's optical adjustments.

- Force HarfBuzz shaping (Firefox default; confirm no platform shaper path is hit).
- Disable platform hinting / optical sizing / tracking that perturbs advances:
  - macOS: disable CoreText optical/tracking adjustments so metrics derive from
    the font, not from CoreText's display tuning.
  - Disable subpixel-positioned advance variation (`gfx.text.*` /
    `gfx.font_rendering.*` — exact prefs to be confirmed on-build).
- This shrinks cross-rasterizer variance but, realistically, will **not** fully
  equalize sub-pixel output across OSes. That residue is what Layer C guarantees.

### Layer C — Metric readback normalization ("do our own kerning")
Goal: whatever the rasterizer produces, the **API the page can read** returns a
deterministic, platform-independent value. This is the belt that makes the
guarantee, and it is a `nsRFPService` patch gated on `privacy.resistFingerprinting`
— the Gecko-native, unbypassable equivalent of what the legacy WKWebView JS shield
did with `measureText` noise and `_bbOff`.

Normalize **every** surface that exposes the transform:
- `CanvasRenderingContext2D.measureText` → quantize `width` **and all `TextMetrics`
  fields** (`actualBoundingBox*`, `fontBoundingBox*`, `emHeight*`).
- `Element.getBoundingClientRect` / `getClientRects` and
  `Range.getBoundingClientRect` / `getClientRects` for text.
- `SVGTextContentElement.getComputedTextLength` / `getSubStringLength` /
  `getExtentOfChar` / `getStartPositionOfChar`.

**Quantization policy (this is the "our own kerning" decision):**
- *Minimum (T3b):* round to integer CSS px. Simple, Tor-ish, kills sub-pixel
  entropy. Some layout shift; sites tolerate it.
- *Best (T3c):* compute advances **directly from font units** —
  `advance = Σ hmtx[glyph] (± GPOS kerning) × fontSize / unitsPerEm`, rounded to a
  fixed grid. Because the bundled font's tables are identical everywhere, this
  yields the **same number on every OS** — true cross-platform uniformity, derived
  from the font, not the rasterizer. This is literally "doing our own kerning."

**Critical distinction — uniform, NOT randomized.** Canvas and audio use
*per-session randomization* (unlinkable noise). Text metrics must be the opposite:
**uniform** — every user and session returns the identical value. Randomizing text
metrics would split the cohort and *add* entropy. The quantizer must be
deterministic and session-stable.

## 3. Verification
- `scripts/measure-fingerprint.mjs` already tracks `non-base fonts` (→ `0/14`) and
  `text-metric readback` (→ `int`). After implementation both flip to cohort/normalized.
- Add kerning-pair cross-checks (AV/To/Wa/Yo + ligatures fj/ffi/fl) to ensure GPOS
  output is uniform, and assert identical metrics across two OSes in CI if a Linux
  runner is available (the cross-platform proof).
- Lock the targets into `verify-gecko-rfp.mjs` once met so they can't regress.

## 4. Where each piece lands
| Piece | Mechanism | Location |
|-------|-----------|----------|
| Font files | packaging | app bundle `Resources/fonts/` + build step |
| Bundled-font activation, generic remap, visibility=1 | prefs | both `settings/profiles/*/user.js` |
| `gfxPlatformFontList` allowlist (exclusivity) | source patch | LibreWolf patch set |
| Shaping/hinting determinism | prefs + maybe patch | user.js + patch set |
| Text-metric quantizer | source patch | `nsRFPService` (gated on RFP) |
| Verification vectors | already present | `measure-fingerprint.mjs` |

## 5. Risks
- **Layout reflow** from quantized/remapped metrics — minor; metric-compatible
  fonts (Arimo/Tinos/Cousine) minimize it; Tor accepts the residual.
- **`local()` bypass** reaching system fonts — closed only by the allowlist patch,
  not by prefs. Do not ship Layer A without it.
- **Coverage gaps** (CJK/emoji) producing tofu — bundle Noto + an emoji font.
- **Pref-name drift** — verify every pref on the actual build (we have a harness
  habit for this now); a misspelled pref is a silent no-op.

## 6. Rollout order
1. **T3a** (prefs + packaging + allowlist patch): font enumeration → `0/14`,
   selection entropy gone. Per-platform uniform.
2. **T3b** (`nsRFPService` integer-round quantizer): `text-metric readback` → `int`.
   Kills the sub-pixel transform readback.
3. **T3c** (font-unit-derived advances): identical metrics across OSes — the
   strongest form, "our own kerning."
