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

Two caveats, stated plainly:
- **Security staleness.** The mirror followed Firefox *release* (140.0.x → 141 → …
  → 150), not the ESR *branch*, so the newest 140 tag is `140.0.4` (mid-2025
  release point), NOT the ESR continuation `140.10.x` that Tor actually ships. At
  the UA layer they're identical (`140.0`), but `140.0.4` misses ~a year of ESR
  security backports. For a privacy browser that's a real gap — the proper fix is
  the mirror tracking the **`mozilla-esr140` branch** (140.10.x) so Tor mode rides
  current-security *and* cohort-matching. Tracked as the next mirror task.
- **Patch re-verification.** The anti-fp patches and the OS-spoof SPEC line numbers
  were resolved against the 150 tree; on 140 the `nsRFPService` / `Navigator`
  offsets differ. `patch` fuzz usually absorbs this, but re-run `check-patchfail.sh`
  against the 140 tag before trusting a Tor-mode build.

Net: Tor mode gives **full network-layer anonymity** plus a JS identity that is
version-aligned to the cohort (140.0) once it rides the 140 line — with the OS-spoof
patch (§OS) closing the last identity gap.

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
