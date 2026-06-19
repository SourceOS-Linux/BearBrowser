# BearBrowser Tor mode

Closing the last gap our anti-fingerprint work can't reach with prefs: the
**network layer** (TLS ClientHello / JA3-JA4, HTTP/2 frame fingerprint, and the
real client IP). RFP normalizes the JS surface; it does nothing about how our TCP
connections look on the wire or where they originate. Only routing through Tor
fixes that — by moving the network fingerprint to Tor's *uniform exit*.

## The strategy: a tier, not a default
BearBrowser runs in one of two modes; the user chooses per session:

- **BearBrowser mode** (default) — our best-in-class *direct-connection* hardening:
  text-metric quantization, audio farble, bundled fonts, full RFP. Beats Tor and
  Brave on the JS surface. Fast.
- **Tor mode** — route through Tor + **blend into the Tor Browser cohort**. Gets
  the network-layer anonymity Tor has. Slower; some sites challenge Tor exits.

Offering both is how we genuinely lead: **everything Tor offers (as a mode) PLUS
our direct-mode innovations Tor doesn't have.**

## The cohort paradox (the thing to get right)
Tor's power is that ~millions of Tor Browser users look **byte-for-byte
identical**. Anonymity = hiding in that crowd. **Uniqueness is the enemy of
anonymity.** So if "BearBrowser over Tor" carried our *extra* protections
(text-metric quantizer, audio farble, our exact build), we'd be a *tiny, distinct
cohort riding Tor* — easier to single out than a default Tor Browser user.

## Spoof normality — don't just turn our tech off
The naive fix is "disable our extra protections in Tor mode." That is only correct
when **off already equals the cohort value.** Turning a protection off can leave us
in a state that *differs* from the Tor crowd — which is exposure, not blending. So
the rule is: **spoof the cohort's normal value; only disable when disabling IS that
value.** Three cases:

| Surface | What we do in Tor mode | Why it's the normal value |
|---|---|---|
| Text-metric quantizer, audio farble | **Disable** | Tor Browser does *neither* — its un-touched values ARE the cohort normal. Off = stock RFP = exactly what Tor emits. |
| Fonts | **Keep** Croscore (Arimo/Tinos/Cousine) | Tor ships the same set — we already match. |
| OS identity (UA / platform / oscpu) | **Actively spoof → Windows** | Tor forces *every* platform to Windows so Mac/Linux hide in the majority. Off would expose our real OS. Needs a patch (see §OS spoof). |
| Locale, WebGL renderer | **Force** en-US, mask GPU | Tor spoofs these; stock RFP alone would leak real locale/GPU. |

> You cannot be *uniquely-best-BearBrowser* and *network-anonymous* at the same
> time. You pick per session. That's the honest physics of it.

## §OS spoof — the biggest lever (needs a patch, not a pref)
Tor Browser presents `Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0)
Gecko/20100101 Firefox/140.0` for **all** desktop platforms. RFP computes its own
UA and **ignores** `general.useragent.override`, so this cannot be a pref — it is an
`nsRFPService` patch across ~8 use-sites (UA, platform, oscpu, appVersion, worker
equivalents, maxTouchPoints). Fully specified in
`gecko-patches/anti-fingerprint/anti-fp-tor-os-spoof.SPEC.md`; the `tor-mode`
profile already sets the trigger pref `bearbrowser.tor-mode.spoof-os=windows`
(a no-op until the patch lands). It is a *coordinated* change — one missed site =
an inconsistent identity that is worse than no spoof — so it is authored with a
compiler in the loop, not blind.

## §version — ride the 140 line, not 150
Default BearBrowser is **Firefox 150**; the live Tor cohort is **Firefox 140 ESR**.
Building Tor mode on 150 leaves `Firefox/150.0` ≠ `Firefox/140.0`, and version-probes
expose the real engine — a 150-over-Tor is a distinct cohort from 140-over-Tor.

**The fix is operational, and now wired in.** RFP freezes the spoofed UA to the
major only (`140.0`), independent of point release — so *any* 140-line build is
fingerprint-equivalent to Tor's 140.x ESR at the UA layer. The upstream mirror
already carries the 140 line (`140.0.4-1`), so `apply-sourceos-overlays.sh
--profile tor-mode` now **auto-pins `latest` to the newest 140-line tag** (override
with `BEARBROWSER_TOR_COHORT_MAJOR` or an explicit `--ref`). No new base, no version
spoofing (which would invite detectable inconsistencies and is not done).

### Current security, not stale 140.0.4 — without touching the mirror
The mirror is a *verbatim* `--mirror` of LibreWolf upstream (the sync `--prune`s
anything not upstream, so we cannot park a custom `esr140` branch there). LibreWolf
tracks Firefox *release*, so its newest 140 tag is `140.0.4` (mid-2025) — ~a year of
ESR security backports behind the `140.x` ESR Tor actually ships.

We close that gap **without modifying the mirror**, because LibreWolf's Makefile
fetches `archive.mozilla.org/.../releases/$(version)/source/firefox-$(version)
.source.tar.xz` purely by version string, and Mozilla hosts the ESR source at the
*same* path. So `apply-sourceos-overlays.sh --profile tor-mode` now:
1. pins the 140-line mirror tag (`140.0.4-1`) for LibreWolf's **build scripts**, then
2. **overrides the workspace `version` file to the current ESR point**
   (`140.12.0esr` default; verified present on archive.mozilla.org), so `make fetch`
   pulls current-security ESR source. RFP still freezes the UA to `140.0`, so the
   cohort match holds. Override via `BEARBROWSER_TOR_FIREFOX_VERSION` (set empty to
   fall back to the mirror's `140.0.4` release pin).

The result: **cohort-matching UA *and* current ESR security**, no mirror change.

### ESR patch-apply — verified in CI
The `tor-esr-patch-apply` job (anti-fingerprint.yml) fetches `firefox-140.12.0esr`
and dry-runs the whole stack with GNU patch on Linux (authoritative). Findings:
- **LibreWolf's stack applies cleanly to ESR** — the only reject is `msix.patch`
  (Windows Store packaging), irrelevant to a Linux/macOS Tor browser, so it's
  dropped from the Tor-mode stack. Note the ESR tarball extracts to
  `firefox-140.12.0` (no `esr` suffix in the dirname).
- **Our anti-fp patches are OMITTED from the Tor-mode build, by design.** Tor mode
  disables CanvasTextMetrics + WebAudioFarble to match the cohort (which quantizes
  neither), so compiling them in only to disable them is pointless — and these
  150-authored patches reject on the 140 tree anyway. Omitting is behaviorally
  identical to disabling-via-override. The default 150 build keeps them active.

### Still open
- **OS-spoof line numbers.** The SPEC offsets were resolved on the 150 tree;
  re-resolve against `firefox-140.12.0` when authoring the patch.
- **The 140.0.4-1 mirror tag's `version` override → ESR dirname mismatch.** The
  LibreWolf Makefile derives the source *dirname* from `$(version)` too, so a
  `version` of `140.12.0esr` makes it look for `firefox-140.12.0esr` while the
  tarball extracts to `firefox-140.12.0`. The real build flow needs the dirname
  decoupled from the esr-suffixed tarball/URL (a small Makefile fixup); the
  patch-apply gate already handles this by discovering the real dir.

Net: Tor mode gives **full network-layer anonymity** plus a JS identity that is
version-aligned to the cohort (`140.0`) on current-security ESR source — with the
OS-spoof patch (§OS) closing the last identity gap.

## Why NOT the others
- **JonDonym / JAP ("johndo"):** defunct — the mixes shut down ~2021, client
  unmaintained. Skipped.
- **I2P / Nym / Lokinet (mixnets):** each *additional* network fragments the
  cohort and they're high-latency / early-stage. Tor has the giant crowd, which
  is the entire point. Deferred indefinitely.
- **obfs4 / Snowflake / meek (pluggable transports):** YES — but they ride *with*
  Tor (censorship circumvention), so they land in Phase 2, not as separate nets.

## Phase 1 — what's shipped (this profile)
`settings/profiles/tor-mode/` — applied on top of the human-secure RFP baseline:
- **SOCKS routing, fail-closed:** all traffic → `127.0.0.1:9050`, `socks_remote_dns`
  (DNS through Tor, no leak), `failover_direct=false` (never silently go direct).
- **Every proxy-bypass vector killed:** WebRTC off, DoH/TRR off (Tor does DNS),
  IPv6 off, HTTP/3/QUIC off (UDP doesn't traverse SOCKS5 cleanly), no
  prefetch/predictor/speculative connects.
- **Proxy LOCKED via enterprise policy** (`Proxy` + `Locked: true`) so no site or
  script can change it and deanonymize the user.
- **Cohort alignment (spoof normality):** RFP on; bundled Croscore fonts kept
  (matches Tor); our unique targets disabled via
  `privacy.fingerprintingProtection.overrides=-CanvasTextMetrics,-WebAudioFarble`
  (off = stock RFP = Tor's value); plus `privacy.spoof_english=2` and
  `webgl.enable-debug-renderer-info=false` to force the locale/GPU values Tor
  spoofs but stock RFP would leak. OS-spoof trigger pref set (patch pending, §OS).

### Running Phase 1 (external tor)
Phase 1 assumes a standalone Tor daemon is already listening on `127.0.0.1:9050`:
```sh
tor            # or: brew services start tor   (macOS),  systemctl start tor (Linux)
# then build/launch BearBrowser with the tor-mode profile:
scripts/apply-sourceos-overlays.sh --profile tor-mode --ref latest
```
Verify routing at `https://check.torproject.org`.

## Phase 2 — bundle + launch Tor
- Vendor the `tor` binary + a control/launcher (à la Tor Browser's tor-launcher):
  start tor on a private port, wait for bootstrap, wire the proxy.
- Bundle **obfs4 / Snowflake / meek** pluggable transports for censored networks.
- A "Tor mode" toggle in the shell (no separate profile build).

## Phase 3 — polish
- Security slider (Standard / Safer / Safest), `.onion` handling + onion-location,
  "New Identity" / "New Circuit", first-party stream isolation by SOCKS auth.

## Honest limitations (don't oversell)
- **Not byte-identical to Tor Browser.** The two open items are the OS spoof (§OS,
  patch pending) and the engine version (§version — we are FF150, the cohort is FF140
  ESR; the real fix is building Tor mode on ESR 140). We are *aligned to* the Tor
  cohort, not yet indistinguishable. The **network-layer anonymity (Tor exit) is
  full** regardless; the JS-fingerprint blend-in is best-effort and improves as we
  ride the same ESR and land the OS-spoof patch.
- **The `overrides` disable of our custom targets must be verified on the real
  build** — the override-syntax handling of patch-added RFPTargets is unconfirmed.
- Tor mode is **only as safe as the leak list is complete** — every new web API
  that can open a non-proxied socket is a potential deanonymization and must be
  audited (this is why Tor Browser is years of work, not a pref file).
