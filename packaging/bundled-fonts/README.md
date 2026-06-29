# BearBrowser bundled fonts (anti-fingerprint)

Metric-compatible font set bundled to give every BearBrowser user — on every OS —
the **identical** font fingerprint. Combined with `font.system.whitelist` (set in
the profile prefs), web content sees only these families; all other installed
fonts are hidden from enumeration (`gfxPlatformFontList::ApplyWhitelist`).
Empirically verified: macOS decorative-font detection drops 13/14 → 0/14.

| Family | Role | Metric-compatible with |
|--------|------|------------------------|
| Arimo   | sans-serif | Arial / Helvetica |
| Tinos   | serif      | Times New Roman |
| Cousine | monospace  | Courier New |

These are the Croscore fonts (the set Tor Browser / Mullvad Browser also use),
chosen because they match the metrics of the ubiquitous MS core fonts, so existing
site layouts don't reflow.

## Provenance & license
- Source: the `google/fonts` repository (`ofl/{arimo,tinos,cousine}`), upstream
  by Monotype Imaging Inc.
- License: **SIL Open Font License 1.1** — see `OFL-Arimo.txt` and `OFL-Cousine.txt`
  (Tinos is part of the same Croscore release and is covered by the same SIL OFL).

## Activation (wired in `scripts/bearbrowser-overlay-binary.sh`, step 6b)
The `.ttf` files are copied into the app bundle at `Contents/Resources/fonts/`
(= `NS_GRE_DIR/fonts`), which Gecko's `ActivateBundledFonts()` loads when
`gfx.bundled-fonts.activate=1`. The matching prefs (`font.system.whitelist`,
`font.name.{serif,sans-serif,monospace}.x-western`) live in both profile
`user.js` files. Source-build packaging (`make package`) must place the same
`fonts/` dir in the GRE.

## Coverage note (follow-up)
This set covers Latin + Cyrillic + Greek. CJK / Arabic / Hebrew / emoji are not
yet bundled — under the whitelist those scripts fall back to nothing (tofu), which
is itself a minor signal. A follow-up should add a Noto subset + an emoji font to
the bundle and the whitelist for full coverage.
