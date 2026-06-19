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

Therefore Tor mode deliberately **disables our unique RFP targets** and aligns to
Tor Browser's configuration. We keep what already matches (the Croscore fonts —
Tor ships the same Arimo/Tinos/Cousine) and drop what would make us stand out.

> You cannot be *uniquely-best-BearBrowser* and *network-anonymous* at the same
> time. You pick per session. That's the honest physics of it.

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
- **Cohort alignment:** RFP on; bundled Croscore fonts kept (matches Tor); our
  unique targets disabled via `privacy.fingerprintingProtection.overrides=
  -CanvasTextMetrics,-WebAudioFarble`.

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
- **Not byte-identical to Tor Browser.** Different build/version → different frozen
  UA, build id, and some RFP details. We are *aligned to* the Tor cohort, not
  indistinguishable from it. The **network-layer anonymity (Tor exit) is full**;
  the JS-fingerprint blend-in is best-effort and improves as we track Tor's config.
- **The `overrides` disable of our custom targets must be verified on the real
  build** — the override-syntax handling of patch-added RFPTargets is unconfirmed.
- Tor mode is **only as safe as the leak list is complete** — every new web API
  that can open a non-proxied socket is a potential deanonymization and must be
  audited (this is why Tor Browser is years of work, not a pref file).
