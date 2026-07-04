# T3 — Implementation Plan / Runbook (font + text-metric uniformity)

Companion to `anti-fingerprint-T3-fonts-text-metrics.md` (the *why*). This is the
*how* — the no-holes execution plan. Authored ahead of build; the compile/
integrate/ship steps happen on the build pipeline.

Guiding rule: **fix it once at the lowest shared layer, not N times at each JS
API.** Every text-metric API is a *consumer* of one thing — the per-glyph advances
the shaper produces. Patch that, and canvas / layout / SVG / Range all inherit the
uniform value. Patching each API is whack-a-mole and *will* leave holes.

## 0. Build-environment on-ramp (turnkey)

You don't need to invent anything here — the project **already ships RFP/FPP
patches through this exact mechanism**: see `patches/fpp-canvas-fix.patch` and
`patches/ui-patches/website-appearance-ui-rfp.patch`, both registered in
`assets/patches.txt`. Our three T3 patches follow that precedent.

### 0.1 The build repo
The LibreWolf-style BearBrowser build repo (the one containing `Makefile`,
`scripts/bearbrowser-patches.py`, `patches/`, `assets/patches.txt`,
`firefox-<version>.source.tar.xz`) is checked out per build under
`build/workspaces/<profile>-<version>/source/`. That `source/` **is** the repo to
work in for Gecko patches. (The product overlay — settings/policy/packaging —
stays in this repo and is layered by `apply-sourceos-overlays.sh`.)

### 0.2 One-time toolchain setup
```
cd <build-repo>
make bootstrap        # extracts source + ./mach bootstrap --application-choice=browser
                      # (installs rust/clang/etc; uses assets/mozconfig.new)
```

### 0.3 Get a stable source tree to edit
```
make patches          # tar xf firefox-<version>.source.tar.xz  -> firefox-<version>/
                      # python3 scripts/bearbrowser-patches.py   -> bearbrowser-<version>-<release>/
```
Edit the **extracted, patched** tree `bearbrowser-<version>-<release>/` (this is
the tree that vanished mid-session — it only exists after `make patches`).

### 0.4 Where each T3 artifact lands
| Artifact | Location | Registration |
|----------|----------|--------------|
| W2 `gfxPlatformFontList` allowlist patch | `patches/anti-fp-font-allowlist.patch` | add to `assets/patches.txt` |
| W4/W5 `gfxShapedText` advance quantizer patch | `patches/anti-fp-text-metrics.patch` | add to `assets/patches.txt` |
| W6 `nsRFPService` audio-noise patch | `patches/anti-fp-audio.patch` | add to `assets/patches.txt` |
| W1 font files (Arimo/Tinos/Cousine/Noto/emoji) | `assets/fonts/` + packaging copy step | packaging script |
| W3 generic-remap prefs | this overlay `settings/profiles/*/user.js` | ships **atomically** with W1 |

### 0.5 Inner dev loop for a patch (fast → full)
```
# 1. edit files under bearbrowser-<version>-<release>/<path>
# 2. produce the diff (the tree is a git checkout, or use diff -u vs pristine):
git -C bearbrowser-<version>-<release> diff -- gfx/thebes/gfxFont.cpp \
    > ../patches/anti-fp-text-metrics.patch        # paths must be -p1 (a/ b/)
# 3. register it
echo "patches/anti-fp-text-metrics.patch" >> assets/patches.txt
# 4. FAST verify it applies cleanly (no compile):
make check-patchfail        # scripts/check-patchfail.sh — catches apply/fuzz errors
# 5. FULL build + run when the patch applies:
make build                  # ./mach build  (the slow step; needs 0.2)
make run                    # ./mach run    (or `make package`)
```
`make check-patchfail` is the tight loop — it tells you the diff applies before
paying for a compile. Gate every patch through it.

### 0.6 Measure the *real* binary (not Playwright)
`measure-fingerprint.mjs` drives Playwright's Firefox, which only works on
Playwright's Juggler-patched build — it **cannot** drive a stock LibreWolf binary.
For the real build use Firefox's own remote protocol:
- `geckodriver` (WebDriver) pointed at the built binary, or Marionette (port 2828).
- Add a geckodriver adapter to the harness (or a thin Marionette probe runner) and
  pass the binary via `BEARBROWSER_BIN`. The same `PROBE` payload is reused.
This is what clears the `screen WxH` (letterboxing) residual that headless
Playwright can't show, and confirms the 75% baseline holds on the real build.

### 0.7 Definition of done (per work item)
Each work item is done when its harness vector flips and stays green:
W1/W2 → `non-base fonts = 0/14`; W4/W5 → `canvas text metric` & `layout text
metric = int` **and** identical across a Mac and a Linux runner (the cross-OS
proof); W6 → `audio (oac)` RANDOMIZED across sessions; W7 → `screen WxH`
normalized on the real binary. Then lock each target into `verify-gecko-rfp.mjs`.

## 1. Complete readback surface (the holes register)

Measured (Gecko 141, our RFP profile). Every row must end up uniform/quantized or
it is a hole.

| Surface | Path | Measured now | Covered by |
|---------|------|--------------|------------|
| `CanvasRenderingContext2D.measureText` (+ all `TextMetrics` fields) | canvas → gfxTextRun | 453.549987… subpixel, RFP-noop | W4 helper |
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
439.60) — proof a single-API fix is insufficient; the quantizer must be a shared
helper called from each path (§2).

## 2. Architecture — `nsRFPService` helper + DOM call sites

**Correction (grounded in the existing `patches/fpp-canvas-fix.patch`).** The first
draft proposed quantizing in `gfxShapedText` (gfx layer) as a single chokepoint.
Reading how this tree actually plumbs RFP shows why that's wrong: RFP gating needs
the **principal + cookie-jar settings** to call `ShouldResistFingerprinting`, and
those are only available at the **DOM layer**, not deep in `gfx/thebes`. The canvas
randomization proves the real pattern — it lives in `dom/canvas/*` and calls
`nsRFPService::RandomizePixels(GetCookieJarSettings(), PrincipalOrNull(), …)`:

```
patches/fpp-canvas-fix.patch:
  dom/canvas/CanvasRenderingContext2D.cpp  → nsRFPService::RandomizePixels(...)
  dom/canvas/ClientWebGLContext.cpp        → gfxUtils::GetImageBufferWithRandomNoise(...)
  (gated by ImageExtraction::Randomize / EfficientRandomize, principal in hand)
```

So the real architecture mirrors that: **one `nsRFPService` helper, called from each
DOM entry point that exposes a text metric.** Not a single gfx chokepoint, but a
single *helper* with a few faithful call sites — exactly how canvas already works.

```
nsRFPService::SpoofTextMetrics(cookieJarSettings, principal, &metrics)   // new helper
        ▲              ▲                         ▲                  ▲
  CanvasRenderingContext2D::MeasureText   Element/Range BCR   SVGTextContentElement::*
  (dom/canvas)                            (dom/base + layout) (dom/svg)
```

Trade-off vs the chokepoint dream: a few more call sites, but each one *has* the
RFP context and matches the established pattern — far more likely to compile and
be accepted than reaching into `gfxShapedText` without a principal. The quantizer
math (round to integer CSS px, or derive from font units — §W4) is unchanged; only
*where* it runs moves up to the DOM, beside the existing canvas RFP code.

Per-glyph note: because all these DOM APIs ultimately read advances that gfx
already rounds to app-units (gfxFont.h: "each glyph advance is always rounded to
the nearest appunit"), the helper quantizes the **returned metric** (total advance
+ bounding-box fields) deterministically — uniform, never randomized (§W4).

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

### W4 — Text-metric quantizer (`nsRFPService` helper + DOM call sites)
Following the `fpp-canvas-fix.patch` pattern (§2), not a gfx chokepoint.
- **New helper** in `nsRFPService` (decl in `.h`, body in `.cpp`), styled like
  `RandomizePixels` — takes cookie-jar settings + principal, early-returns unless
  `ShouldResistFingerprinting(...)`, then quantizes in place:
  - *T3b (minimum):* round each exposed length to whole CSS px.
  - *T3c (best, "our own kerning"):* derive from font units —
    `len = round(Σ hmtxAdvance ± GPOS × size / unitsPerEm)` — font-intrinsic,
    identical on every OS, independent of the platform rasterizer.
- **Call sites** (each has the principal in hand, like the canvas patch):
  - `dom/canvas/CanvasRenderingContext2D::MeasureText` — quantize `width` + every
    `TextMetrics` field (`actual/font/emHeight*`).
  - `Element::GetBoundingClientRect` / `GetClientRects`, `Range` equivalents
    (`dom/base`, via `nsLayoutUtils`) — quantize the returned rect for text.
  - `SVGTextContentElement::{GetComputedTextLength,GetSubStringLength,
    GetExtentOfChar,…}` (`dom/svg`).
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
