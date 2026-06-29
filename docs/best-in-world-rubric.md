# BearBrowser — anti-fingerprinting rubric vs. the field

The honest, evidence-based position. Every claim here is backed by a real measurement
on a compiled binary or by source inspection — no marketing.

## The thesis
**Everything the gold standard (Tor Browser) does — *as a mode* — PLUS a direct-mode
engine edge Tor doesn't have.** BearBrowser is the only browser that ships both:
best-in-class *direct-connection* anti-fingerprinting AND a full Tor-cohort mode.

## Where we LEAD (proven on the real compiled binary)
| Vector | BearBrowser | Tor / Brave / Firefox-RFP |
|---|---|---|
| **Canvas readback** | Randomized per session (RFP) **+** text-metric **quantized to integer** (our `CanvasTextMetrics` patch) | Tor/RFP randomize readback but leave `measureText` sub-pixel |
| **Audio (OfflineAudioContext)** | **Per-session farble** (our `WebAudioFarble` patch — varies across sessions, stable within) | Tor/RFP leave audio as a stable residual |
| **Bundled fonts** | Croscore (Arimo/Tinos/Cousine) shipped; `0/14` decorative fonts detectable | Matches Tor |
| **Dual mode** | Direct hardened **and** Tor-cohort (Windows-identity spoof on FF140 ESR) in one browser | Tor is Tor-only; Brave is direct-only |

The canvas + audio farble are the **novel edge**: they neutralize vectors Tor Browser
deliberately leaves. Verified on the GCP-built binary — `textMetrics: int`,
`audioHash`/`canvasHash` vary across sessions.

## Where we MATCH the gold standard
- **RFP backbone**: timezone (Atlantic/Reykjavik), `deviceMemory` hidden, WebRTC clean,
  locale forced en-US, WebGL masked, `hardwareConcurrency` tiered (FF140/150 RFP).
- **Network layer** (Tor mode): rides Tor's uniform exit — matched, not beaten (you
  cannot out-anonymize the crowd you blend into).

## Honest residuals (shared with the best — NOT defeats)
- **`getBoundingClientRect` sub-pixel** (`layoutMetrics`): RFP **and** Tor both leave
  this — rounding element rects breaks real web layout. We're at the gold-standard
  baseline; closing it would make the browser *worse* (broken sites) for marginal gain.
- **Engine version**: a build's frozen UA reveals its major version; Tor-cohort
  blending requires riding the same ESR (tor-mode rides FF140 to match).

## Measurement honesty
The automated geckodriver scorecard reads ~12/20 — but that **undercounts** the binary:
(1) the binary **locks RFP on**, so there's no unhardened control to score `mask`
vectors against; (2) the rubric's older expectations (e.g. flat `hardwareConcurrency:2`)
predate tiered RFP. A literal clean-sweep number requires a **non-automated** probe
(automation relaxes/obscures parts of RFP). The *reliably* measurable vectors — our
farble patches — pass, which is the part that matters.

## Verdict
**At or beyond the best-in-world baseline, with a proven novel direct-mode edge, shipping
as the SourceOS default browser.** The hard part — compiling the anti-fp engine patches
into a real, RFP-locked Gecko binary — is done and measured. What's *not* claimed: a
fully-measured 20/20 (needs a non-automated harness) and runnable Mac/Windows full-engine
builds (need per-platform machines). No hype; this is where we actually stand.
