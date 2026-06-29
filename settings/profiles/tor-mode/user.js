// BearBrowser — Tor mode profile (Phase 1).
//
// Closes the one gap pref-hardening can't: the NETWORK LAYER (TLS ClientHello /
// JA3-JA4, HTTP/2 frame fingerprint, real IP). It routes all traffic through a
// local Tor SOCKS proxy, so the network fingerprint becomes Tor's uniform exit.
//
// This is the Tor DELTA — it is applied ON TOP OF the human-secure RFP baseline
// (same RFP/canvas/WebGL/letterboxing/timezone hardening). It adds the proxy,
// removes leak vectors, and ALIGNS our fingerprint toward the Tor Browser cohort.
//
// THE COHORT PARADOX (read docs/tor-mode.md): Tor's value is that all Tor Browser
// users look identical. Our unique innovations (text-metric quantizer, audio
// farble) would make us a tiny DISTINCT cohort riding Tor — easier to single out,
// not harder. So in Tor mode we deliberately DISABLE those, to blend in. We keep
// the bundled Croscore fonts (Arimo/Tinos/Cousine) because that is ALSO Tor
// Browser's font set — there we already match.
//
// Phase 1 assumes an EXTERNAL tor daemon on 127.0.0.1:9050 (standalone tor) — see
// the doc. Phase 2 bundles + launches tor and obfs4/Snowflake automatically.

// ── Route everything through Tor's SOCKS proxy ───────────────────────────────
user_pref("network.proxy.type", 1);                  // 1 = manual proxy config
user_pref("network.proxy.socks", "127.0.0.1");
user_pref("network.proxy.socks_port", 9050);         // standalone tor (9150 = TB bundle)
user_pref("network.proxy.socks_version", 5);
// DNS resolved THROUGH the SOCKS proxy (by Tor), never locally — no DNS leak.
user_pref("network.proxy.socks_remote_dns", true);
// Proxy literally everything; no host is exempt.
user_pref("network.proxy.no_proxies_on", "");
// NEVER fall back to a direct connection if the proxy fails — a direct fallback
// would deanonymize the user. Fail closed.
user_pref("network.proxy.failover_direct", false);
// Allow proxying localhost/.onion (Tor resolves .onion at the exit/HS layer).
user_pref("network.proxy.allow_hijacking_localhost", true);

// ── Kill every proxy-bypass / IP-leak vector ─────────────────────────────────
// WebRTC opens UDP paths that bypass the SOCKS proxy and reveal the real IP.
// In Tor mode it must be OFF entirely (not just ICE-hardened).
user_pref("media.peerconnection.enabled", false);
// Our DoH/TRR resolver must be OFF in Tor mode — DNS goes through Tor, not Quad9.
user_pref("network.trr.mode", 5);                    // 5 = TRR explicitly disabled
// No speculative connections / prefetch / predictor — they can race ahead of the
// proxy or leak intent.
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.predictor.enabled", false);
user_pref("network.prefetch-next", false);
// Disable IPv6 to avoid a non-Tor IPv6 path (Tor SOCKS is v4-localhost).
user_pref("network.dns.disableIPv6", true);
// HTTP/3/QUIC is UDP — it does not traverse a SOCKS5 TCP proxy cleanly; disable
// so traffic stays on proxied TCP (matches Tor Browser).
user_pref("network.http.http3.enable", false);

// ── RFP backbone (same as the human-secure cohort) ───────────────────────────
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.letterboxing", true);
user_pref("privacy.resistFingerprinting.reduceTimerPrecision", true);
user_pref("privacy.resistFingerprinting.reduceTimerPrecision.microseconds", 1000);
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.partition.network_state", true);
user_pref("security.tls.enable_0rtt_data", false);
user_pref("intl.accept_languages", "en-US, en");
user_pref("javascript.use_us_english_locale", true);

// ── Cohort alignment with Tor Browser ────────────────────────────────────────
// Keep the bundled Croscore fonts — Tor Browser ships the SAME set, so here we
// already match its cohort (do NOT diverge to a different font set in Tor mode).
user_pref("gfx.bundled-fonts.activate", 1);
user_pref("font.system.whitelist", "Arimo, Tinos, Cousine");
user_pref("font.name.serif.x-western", "Tinos");
user_pref("font.name.sans-serif.x-western", "Arimo");
user_pref("font.name.monospace.x-western", "Cousine");
// PRINCIPLE: spoof normality, don't expose. Where "off" already EQUALS the Tor
// cohort value, turning our extra tech off IS the spoof. Where our default DIFFERS
// from the cohort, we must actively emit the cohort value — never sit exposed.
//
// (a) Disable our two custom RFP targets. Tor Browser does NOT quantize text
// metrics and does NOT farble audio — those un-touched values ARE the cohort
// normal. So "off" here = stock RFP = exactly what a real Tor Browser emits: this
// is spoofing normality, not opening a gap. (Verify override syntax on real build.)
user_pref("privacy.fingerprintingProtection.overrides", "-CanvasTextMetrics,-WebAudioFarble");
//
// (b) Actively force the things Tor Browser spoofs that stock RFP does NOT, so we
// never sit in a distinguishable state:
user_pref("privacy.spoof_english", 2);                 // force en-US surface (Tor does)
user_pref("webgl.enable-debug-renderer-info", false);  // mask real GPU vendor/renderer
//
// (c) The BIG one: Tor makes EVERY desktop platform report Windows so Mac/Linux
// users hide in the Windows majority. RFP computes its own UA and IGNORES
// general.useragent/platform/oscpu.override, so this is NOT a pref — it is the
// compile-time OS-spoof patch (gecko-patches/anti-fingerprint/
// anti-fp-tor-os-spoof.patch), built in via -DBEARBROWSER_FORCE_WIN_SPOOF which
// apply-sourceos-overlays.sh --profile tor-mode sets. Nothing to set here.
//
// Match Tor Browser's first-party isolation posture.
user_pref("privacy.firstparty.isolate", false);     // dFPI supersedes; keep consistent
user_pref("privacy.partition.serviceWorkers", true);

// NOTE / honest residual: even here BearBrowser is NOT byte-identical to genuine
// Tor Browser (different build/version → different frozen UA, build id, etc.), so
// we are "aligned to the Tor cohort," not indistinguishable from it. The
// NETWORK-LAYER anonymity (Tor exit) is full regardless; the JS-fingerprint
// blend-in is best-effort. See docs/tor-mode.md §limitations.
