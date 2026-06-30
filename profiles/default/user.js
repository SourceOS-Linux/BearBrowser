// BearBrowser fingerprinting shield — 101 surfaces (Linux)
// Source of truth: profiles/default/user.js — consumed by all platform packaging

// COHORT RECONCILIATION (2026-06-30): this packaging-default shield is the runtime
// default for the SHIPPED packages, so it must match the SAME stock-RFP cohort
// posture the compiled profiles use — NOT a hand-rolled spoof set. Several prefs
// below were either stale no-ops or active OVER-HARDENING that would make the
// browser STAND OUT from the Firefox-ESR/Tor cohort. Each fix is annotated.

// ── Canvas fingerprinting ─────────────────────────────────────────────────────
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.block_mozAddonManager", true);
// REMOVED canvas.poisondata=true — NO-OP. Canvas randomization is always-on under
// RFP since Firefox bug 1816189; the legacy poisondata/randomDataOnCanvasExtract
// prefs were removed (bug 1670447) and do nothing. RFP injects per-session canvas
// noise automatically (== the Tor cohort). Re-adding them is a stale no-op.

// ── WebGL — PRESENT + RFP-MASKED (cohort), not disabled, not hand-spoofed ─────
// REMOVED webgl.renderer-string-override / webgl.vendor-string-override: hardcoding
// "Intel Iris OpenGL Engine" / "Intel Inc." emits a FIXED, DISTINCTIVE renderer
// string that is NOT what the Firefox-ESR/Tor cohort reports — it stands out and,
// worse, differs from RFP's own uniform masking (an inconsistent identity). Tor
// Browser ships WebGL present with RFP masking VENDOR/RENDERER/UNMASKED_RENDERER
// to a uniform cohort value and returning the standardized extension list. Let RFP
// own it: keep WebGL ENABLED (so getContext('webgl') is non-null and the debug
// extension/ext-count are present, not the scorecard's `no-webgl`/undefined leak),
// and do NOT override the renderer string.
user_pref("webgl.disabled", false);
user_pref("webgl.enable-webgl2", true);

// ── AudioContext fingerprinting ───────────────────────────────────────────────
// REMOVED privacy.resistFingerprinting.randomDataOnCanvasExtract — this pref was a
// NO-OP here (it was never an audio pref; the real one was removed in bug 1670447,
// see canvas note above). Audio handling is owned by RFP (and, in the direct/
// human-secure build, by the WebAudioFarble patch). No stale pref needed.

// ── Font fingerprinting — bundled-font allowlist (cohort uniformity) ──────────
user_pref("gfx.font_rendering.graphite.enabled", false);
// FIXED font.system.whitelist: was "" (empty = NO allowlist applied = every
// installed OS font enumerable = the real font-fingerprint leak). Align to the
// compiled profiles' Croscore bundle (Arimo/Tinos/Cousine) so every OS exposes the
// SAME font set — the Tor/Mullvad cross-platform-uniformity approach.
user_pref("gfx.bundled-fonts.activate", 1);
user_pref("font.system.whitelist", "Arimo, Tinos, Cousine");
user_pref("font.name.serif.x-western", "Tinos");
user_pref("font.name.sans-serif.x-western", "Arimo");
user_pref("font.name.monospace.x-western", "Cousine");
// REMOVED browser.display.use_document_fonts=0 — forcing 0 BLOCKS web fonts
// entirely, which both breaks sites AND is a distinctive non-cohort behavior
// (Tor/ESR render web fonts). The whitelist above is the correct font-leak fix.

// ── Timezone / timing ─────────────────────────────────────────────────────────
user_pref("privacy.resistFingerprinting.reduceTimerPrecision.unconditional", true);
user_pref("privacy.reduceTimerPrecision", true);
user_pref("privacy.reduceTimerPrecision.microseconds", 1000);
user_pref("javascript.options.wasm_trustedprincipals", false);

// ── WebRTC ────────────────────────────────────────────────────────────────────
user_pref("media.peerconnection.ice.no_host", true);
user_pref("media.peerconnection.ice.proxy_only_if_behind_proxy", true);
user_pref("media.peerconnection.enabled", true);
user_pref("media.peerconnection.ice.link_local", false);

// ── Navigator normalization — owned by RFP, NOT manual overrides ──────────────
// REMOVED general.useragent/platform/oscpu/appname/appversion.override. RFP
// computes its OWN frozen UA/platform/oscpu and IGNORES these overrides (see
// docs/tor-mode.md §OS spoof). Worse, the values here were stale and INCONSISTENT
// with the cohort: a hardcoded rv:128.0 / Firefox/128.0 UA pinned to a year-old
// engine, contradicting RFP's computed UA — an inconsistent-identity leak. The
// cohort UA is produced by RFP (frozen to the ESR major); for Tor mode the
// Windows-OS spoof is a compile-time patch, not a pref. Let the engine own it.

// ── Hardware concurrency ──────────────────────────────────────────────────────
// RFP standardizes navigator.hardwareConcurrency to the cohort value (the scorecard
// expects 2). A hand-set 4 here would override RFP toward a non-cohort value, so we
// do NOT set dom.maxHardwareConcurrency — RFP owns it (matching Tor/ESR).

// ── Battery API ───────────────────────────────────────────────────────────────
user_pref("dom.battery.enabled", false);

// ── Sensors ───────────────────────────────────────────────────────────────────
user_pref("device.sensors.enabled", false);
user_pref("device.sensors.ambientLight.enabled", false);
user_pref("device.sensors.motion.enabled", false);
user_pref("device.sensors.orientation.enabled", false);
user_pref("device.sensors.proximity.enabled", false);
user_pref("dom.gamepad.enabled", false);
user_pref("dom.gamepad.extensions.enabled", false);

// ── Network fingerprinting ────────────────────────────────────────────────────
user_pref("network.http.sendRefererHeader", 2);
user_pref("network.http.referer.spoofSource", false);
user_pref("network.http.sendSecureXSiteReferrer", false);
user_pref("network.cookie.cookieBehavior", 5);
// REMOVED network.http.http3.enabled=false — MISSPELLED (trailing 'd'); the real
// pref is network.http.http3.enable, so this was a silent no-op. We deliberately do
// NOT disable HTTP/3 in the direct/default shield: the QUIC-speaking majority is the
// crowd to blend into, and Tor Browser does not disable HTTP/3 in direct use. (Tor
// MODE disables it — UDP can't traverse SOCKS5 — but that lives in the tor-mode
// profile, not this default shield.)
user_pref("network.http.connection-retry-timeout", 0);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("network.predictor.enable-prefetch", false);
user_pref("network.http.speculative-parallel-limit", 0);

// ── Tracking protection ───────────────────────────────────────────────────────
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.pbmode.enabled", true);
user_pref("privacy.trackingprotection.annotate_channels", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
user_pref("privacy.trackingprotection.cryptomining.enabled", true);
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.trackingprotection.origin_telemetry.enabled", false);
// FIXED: was privacy.firstparty.isolate=true (legacy FPI). The Firefox-ESR/Tor
// cohort uses dynamic First-Party Isolation (dFPI) via partitioned network state,
// NOT the deprecated FPI flag — keeping FPI on diverges from the cohort and can
// break sites. Align to dFPI/partitioning (set below) and drop the FPI flags.
user_pref("privacy.partition.network_state", true);
user_pref("privacy.partition.serviceWorkers", true);

// ── Telemetry off ─────────────────────────────────────────────────────────────
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);
user_pref("toolkit.telemetry.hybridContent.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);

// ── Google services off ───────────────────────────────────────────────────────
user_pref("geo.provider.network.url", "");
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("browser.safebrowsing.blockedURIs.enabled", false);
user_pref("browser.safebrowsing.provider.google.advisoryURL", "");
user_pref("browser.safebrowsing.provider.google4.advisoryURL", "");
user_pref("services.sync.enabled", false);
user_pref("browser.aboutHomeSnippets.updateUrl", "");

// ── Cache side-channel mitigation ─────────────────────────────────────────────
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.offline.enable", false);
user_pref("security.OCSP.enabled", 1);
user_pref("security.OCSP.require", true);
user_pref("security.cert_pinning.enforcement_level", 2);

// ── Media / codec fingerprinting ─────────────────────────────────────────────
user_pref("media.navigator.enabled", false);
user_pref("media.navigator.video.enabled", false);
user_pref("media.getusermedia.screensharing.enabled", false);
user_pref("media.getusermedia.audiocapture.enabled", false);

// ── Misc privacy ─────────────────────────────────────────────────────────────
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.newtab.url", "about:blank");
user_pref("browser.urlbar.speculativeConnect.enabled", false);
user_pref("browser.urlbar.trimURLs", false);
user_pref("layout.css.visited_links_enabled", false);
user_pref("dom.indexedDB.enabled", true);
user_pref("dom.storage.enabled", true);
user_pref("dom.allow_cut_copy", false);
user_pref("dom.event.clipboardevents.enabled", false);
user_pref("clipboard.autocopy", false);
user_pref("extensions.pocket.enabled", false);
user_pref("extensions.screenshots.disabled", true);
user_pref("reader.parse-on-load.enabled", false);
