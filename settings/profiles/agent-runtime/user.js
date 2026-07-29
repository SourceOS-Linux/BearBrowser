// =============================================================================
// BearBrowser — Agent Browser Runtime Profile
// =============================================================================
// This file configures Firefox/LibreWolf prefs for the Agent Browser Runtime
// mode of BearBrowser. It is loaded from the agent-runtime profile directory
// and is intended to be used exclusively by automated AI agents — never by
// human users browsing interactively.
//
// Design goals:
//   1. Zero state accumulation: nothing written to disk persists across sessions.
//   2. No credential inheritance: agents must not pick up cookies, saved logins,
//      or session tokens left by any previous session (human or agent).
//   3. No data exfiltration surfaces: WebRTC, push, service workers, and other
//      side-channels that can leak IP/identity are disabled entirely.
//   4. Strong fingerprint resistance: agents should blend into the same
//      privacy-hardened baseline as human-secure profiles.
//   5. Minimal attack surface: features that agents have no operational need
//      for (camera, microphone, VR, battery API, geolocation) are fully off.
//
// PolicyFabric is the authority for all per-site overrides. Prefs here are the
// floor; policies.json enforces the ceiling via the Enterprise Policy engine.
// =============================================================================

// -----------------------------------------------------------------------------
// 1. SESSION / STORAGE ISOLATION
// No state should survive a session boundary. Every agent task starts clean.
// -----------------------------------------------------------------------------

// Do not write session data to disk at all.
user_pref("browser.sessionstore.enabled", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.resume_session_once", false);
// Flush session store immediately on close so nothing lingers.
user_pref("browser.sessionstore.interval", 2147483647); // max int — effectively never checkpoint

// No browsing history (Places database stays empty).
user_pref("places.history.enabled", false);

// No form autofill or saved logins.
user_pref("signon.rememberSignons", false);
user_pref("signon.autofillForms", false);
user_pref("signon.generation.enabled", false);
user_pref("signon.management.page.breach-alerts.enabled", false);
user_pref("browser.formfill.enable", false);

// No offline storage / IndexedDB persistence across profiles.
// (Per-session IndexedDB is still allowed for site functionality;
//  private browsing mode handles isolation via autostart below.)
user_pref("browser.cache.offline.enable", false);
user_pref("browser.cache.offline.capacity", 0);

// Sanitize everything on shutdown — belt-and-suspenders on top of private mode.
user_pref("privacy.sanitize.sanitizeOnShutdown", true);
user_pref("privacy.clearOnShutdown.cache", true);
user_pref("privacy.clearOnShutdown.cookies", true);
user_pref("privacy.clearOnShutdown.downloads", true);
user_pref("privacy.clearOnShutdown.formdata", true);
user_pref("privacy.clearOnShutdown.history", true);
user_pref("privacy.clearOnShutdown.offlineApps", true);
user_pref("privacy.clearOnShutdown.sessions", true);
user_pref("privacy.clearOnShutdown.siteSettings", false); // keep pref overrides
user_pref("privacy.clearOnShutdown.openWindows", true);
// v2 API (FF 128+)
user_pref("privacy.clearOnShutdown_v2.cache", true);
user_pref("privacy.clearOnShutdown_v2.cookiesAndStorage", true);
user_pref("privacy.clearOnShutdown_v2.downloads", true);
user_pref("privacy.clearOnShutdown_v2.formdata", true);
user_pref("privacy.clearOnShutdown_v2.historyFormDataAndDownloads", true);

// No download history written to disk.
user_pref("browser.download.useDownloadDir", false);
user_pref("browser.download.always_ask_before_handling_new_types", true);
user_pref("browser.download.manager.addToRecentDocs", false);
// Agent downloads should be explicitly handled by the orchestration layer, not
// auto-opened or stored in a fixed dir where other processes could read them.

// -----------------------------------------------------------------------------
// 2. PRIVACY / FINGERPRINTING — human-secure baseline
// Agents must be indistinguishable from privacy-hardened human browsers.
// Unique fingerprints would allow cross-session tracking of agent tasks.
// -----------------------------------------------------------------------------

// Master fingerprint resistance switch (RFP).
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.block_mozAddonManager", true);

// Letterboxing: round window dimensions to standard buckets so viewport size
// cannot be used as a fingerprint component.
user_pref("privacy.resistFingerprinting.letterboxing", true);

// Canvas randomization is always-on under RFP (Firefox bug 1816189). The former
// privacy.resistFingerprinting.randomDataOnCanvasExtract pref was removed in bug
// 1670447 and is a no-op — do not re-add it.

// RFP backbone — set explicitly so the agent profile blends into the SAME RFP
// cohort as human-secure (see profile intent above) and is immune to upstream
// default drift. These mirror human-secure/user.js exactly.
// Timer precision: 1ms granularity via nsRFPService (main thread, workers, rAF).
user_pref("privacy.resistFingerprinting.reduceTimerPrecision", true);
user_pref("privacy.resistFingerprinting.reduceTimerPrecision.microseconds", 1000);
// Font visibility: base system fonts only — blocks installed-font enumeration in
// the C++ layout path that JS-level overrides miss.
user_pref("layout.css.font-visibility.standard", 2);
user_pref("layout.css.font-visibility.private", 1);
user_pref("layout.css.font-visibility.trackingprotection", 2);
// Bundled-font allowlist (parity with human-secure): Gecko's font.system.whitelist
// filters the installed font list to only the bundled metric-compatible families,
// so web content can't enumerate other fonts (measured 13/14 -> 0/14). Safe: if
// the bundled fonts aren't present, ApplyWhitelist ignores the list.
user_pref("gfx.bundled-fonts.activate", 1);
user_pref("font.system.whitelist", "Arimo, Tinos, Cousine");
user_pref("font.name.serif.x-western", "Tinos");
user_pref("font.name.sans-serif.x-western", "Arimo");
user_pref("font.name.monospace.x-western", "Cousine");
user_pref("font.default.x-western", "sans-serif");
// Locale normalization: Accept-Language header + JS Intl locale fixed to en-US.
user_pref("intl.accept_languages", "en-US, en");
user_pref("javascript.use_us_english_locale", true);
user_pref("network.http.accept-language", "en-US,en;q=0.5");

// Strict Enhanced Tracking Protection.
user_pref("browser.contentblocking.category", "strict");
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
user_pref("privacy.trackingprotection.cryptomining.enabled", true);
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.trackingprotection.emailtracking.enabled", true);
user_pref("privacy.trackingprotection.pbmode.enabled", true);

// Dynamic First-Party Isolation (dFPI / Total Cookie Protection).
// Partitions all storage by top-level eTLD+1, preventing cross-site tracking
// even within a single agent session.
user_pref("network.cookie.cookieBehavior", 5); // reject third-party, partition first-party
user_pref("network.cookie.cookieBehavior.pbmode", 5);
user_pref("privacy.partition.network_state", true);
user_pref("privacy.partition.network_state.ocsp_cache", true);
user_pref("privacy.partition.serviceWorkers", true);
user_pref("privacy.partition.bloburl_per_agent_cluster", true);
user_pref("privacy.firstparty.isolate", false); // dFPI supersedes legacy FPI; avoid conflict
// QUIC/TLS cross-connection supercookie defense-in-depth: disable 0-RTT early
// data. The cross-site linkability of QUIC NEW_TOKEN tokens (RFC 9000 §8.1/§19.7)
// and TLS/QUIC 0-RTT session tickets (RFC 9001 §4.6, RFC 8446 §C.4) is already
// closed by network-state partitioning above; disabling early data additionally
// removes the 0-RTT replay surface. Mirrors human-secure.
user_pref("security.tls.enable_0rtt_data", false);

// DNS over HTTPS — Quad9, strict mode, no fallback to OS resolver.
// Quad9 (Swiss non-profit, GDPR) preferred over Cloudflare: no commercial data
// incentive, and does NOT forward EDNS Client Subnet (RFC 7871) to authoritative
// servers. 9.9.9.9 = filtered + DNSSEC + NO ECS (9.9.9.11 forwards ECS — avoid).
// IP-form URL needs no bootstrap (cert SAN covers the IP). Mirrors human-secure.
user_pref("network.trr.mode", 3); // 3 = TRR only, hard-fail
user_pref("network.trr.uri", "https://9.9.9.9/dns-query");
user_pref("network.trr.custom_uri", "https://9.9.9.9/dns-query");
user_pref("network.trr.confirmationNS", "skip");
// ECS suppression, DNS-rebinding guard, no-UA-to-resolver, query padding.
user_pref("network.trr.disable-ECS", true);
user_pref("network.trr.allow-rfc1918", false);
user_pref("network.trr.send_user-agent-headers", false);
user_pref("network.trr.padding", true);

// HTTP/3 + DNS HTTPS-RR posture — mirror human-secure so agents share the same
// network cohort. HTTP/3 on; Alt-Svc off (H3 discovered only via DNS HTTPS/SVCB
// records, RFC 9460); ECH encrypts SNI via the same HTTPS RR.
user_pref("network.http.http3.enable", true);
user_pref("network.http.altsvc.enabled", false);
user_pref("network.http.altsvc.oe", false);
user_pref("network.dns.use_https_rr_as_altsvc", true);
user_pref("network.dns.upgrade_with_https_rr", true);
user_pref("network.dns.echconfig.enabled", true);
user_pref("network.dns.http3_echconfig.enabled", true);
// Trim cross-origin referers to scheme+host+port — parity with human-secure.
user_pref("network.http.referer.XOriginTrimmingPolicy", 2);

// No link prefetch, no speculative pre-connections.
// These make network requests that agents have not explicitly authorised.
user_pref("network.prefetch-next", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
user_pref("network.predictor.enabled", false);
user_pref("network.predictor.enable-prefetch", false);
user_pref("network.http.speculative-parallel-limit", 0);

// HTTPS-only mode: refuse to load any page over plain HTTP.
user_pref("dom.security.https_only_mode", true);
user_pref("dom.security.https_only_mode_pbm", true);
user_pref("dom.security.https_only_mode_ever_enabled", true);

// TLS hardening — parity with human-secure: TLS 1.2 floor / 1.3 ceiling, and
// refuse unsafe (legacy) renegotiation. Narrows the ClientHello to the modern
// cohort and rejects downgrade-prone handshakes.
user_pref("security.tls.version.min", 3);
user_pref("security.tls.version.max", 4);
user_pref("security.ssl.require_safe_negotiation", true);
user_pref("security.ssl.treat_unsafe_negotiation_as_broken", true);

// Referrer policy: send only origin on cross-origin requests.
// Prevents leaking full URL path to third parties.
user_pref("network.http.referer.defaultPolicy", 2);            // strict-origin-when-cross-origin
user_pref("network.http.referer.defaultPolicy.pbmode", 2);
user_pref("network.http.sendSecureXSiteReferrer", false);

// Disable Safe Browsing — it phones home to Google with URL hashes.
// Agent traffic should not be profiled by external services.
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("browser.safebrowsing.blockedURIs.enabled", false);
user_pref("browser.safebrowsing.provider.google4.gethashURL", "");
user_pref("browser.safebrowsing.provider.google4.updateURL", "");
user_pref("browser.safebrowsing.provider.google.gethashURL", "");
user_pref("browser.safebrowsing.provider.google.updateURL", "");
user_pref("browser.safebrowsing.downloads.enabled", false);
user_pref("browser.safebrowsing.downloads.remote.enabled", false);
user_pref("browser.safebrowsing.passwords.enabled", false);

// No disk cache — all agent fetches go through the memory cache only.
// This prevents cached responses from leaking between tasks or being read
// by other processes on the host.
user_pref("browser.cache.disk.enable", false);
user_pref("browser.cache.disk.capacity", 0);
user_pref("browser.cache.disk.smart_size.enabled", false);
user_pref("browser.cache.memory.enable", true); // in-memory cache is fine
user_pref("browser.cache.memory.capacity", 65536); // 64 MB ceiling

// -----------------------------------------------------------------------------
// 3. AGENT-SPECIFIC LOCKDOWN
// Features that agents have no operational need for are disabled here.
// The principle is: if an agent task never legitimately requires a capability,
// that capability is attack surface and must be off.
// -----------------------------------------------------------------------------

// --- Private browsing: force all agent sessions into private mode ---
// Private mode ensures IndexedDB, localStorage, and service worker caches are
// never written to disk, and are wiped when the window closes. This is the
// single most important isolation primitive for agent sessions.
user_pref("browser.privatebrowsing.autostart", true);

// --- WebRTC: completely disabled ---
// WebRTC can expose the real host IP even behind a VPN/proxy via STUN probes.
// Agents must route all traffic through the designated proxy; any WebRTC leak
// would bypass that channel and expose infrastructure topology.
user_pref("media.peerconnection.enabled", false);
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);

// --- Camera / microphone enumeration ---
// Agents don't use A/V input. Disabling navigator.mediaDevices prevents sites
// from fingerprinting hardware configuration via device enumeration.
user_pref("media.navigator.enabled", false);
user_pref("media.navigator.video.enabled", false);
user_pref("media.getusermedia.video.enabled", false);
user_pref("media.getusermedia.audio.enabled", false);

// --- Push notifications and service workers ---
// Service workers run persistent background scripts that survive page unload.
// In an agent profile they could accumulate state, cache data, or be exploited
// to exfiltrate information out-of-band between tasks.
user_pref("dom.serviceWorkers.enabled", false);
user_pref("dom.push.enabled", false);
user_pref("dom.push.connection.enabled", false);
user_pref("dom.webnotifications.enabled", false);
user_pref("dom.webnotifications.serviceworker.enabled", false);
user_pref("dom.webnotifications.requireinteraction.enabled", false);

// --- Hardware / sensor APIs ---
// These APIs can be used for fingerprinting and serve no agent purpose.
user_pref("device.sensors.enabled", false);
user_pref("device.sensors.ambientLight.enabled", false);
user_pref("device.sensors.motion.enabled", false);
user_pref("device.sensors.orientation.enabled", false);
user_pref("device.sensors.proximity.enabled", false);
user_pref("dom.battery.enabled", false);
user_pref("dom.vr.enabled", false);
user_pref("dom.gamepad.enabled", false);

// --- Geolocation ---
user_pref("geo.enabled", false);
user_pref("geo.provider.use_gpsd", false);
user_pref("geo.provider.use_corelocation", false);

// --- Autocomplete / search suggestions ---
// These send partial keystrokes to external servers. Not appropriate for
// agent sessions that may type sensitive query strings.
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("browser.urlbar.quicksuggest.enabled", false);
user_pref("browser.urlbar.speculativeConnect.enabled", false);
user_pref("browser.search.suggest.enabled", false);
user_pref("browser.search.suggest.enabled.private", false);

// --- Translation ---
// Firefox Translations runs locally, but the opt-in check can phone home.
// Disable entirely; agents can use their own translation pipeline.
user_pref("browser.translations.enable", false);

// --- Extensions in private browsing ---
// Extensions must be explicitly allowlisted; none should auto-enable in the
// agent profile's private browsing sessions.
user_pref("extensions.allowPrivateBrowsingByDefault", false);

// --- Miscellaneous lockdown ---
user_pref("dom.disable_window_open_feature.status", true);
user_pref("dom.disable_open_during_load", true);
user_pref("dom.popup_allowed_events", "");
user_pref("dom.disable_window_flip", true);
user_pref("dom.disable_window_move_resize", true);
user_pref("network.http.windows-sso.enabled", false); // no Windows SSO credential injection
user_pref("network.auth.subresource-http-auth-allow", 1); // restrict HTTP auth dialogs

// -----------------------------------------------------------------------------
// 4. TELEMETRY — belt-and-suspenders
// These are redundant with policies.json but set here so they apply even if
// the Enterprise Policy layer is bypassed (e.g. during development).
// -----------------------------------------------------------------------------

user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.firstShutdownPing.enabled", false);
user_pref("toolkit.telemetry.coverage.opt-out", true);
user_pref("toolkit.coverage.opt-out", true);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);

// No crash reports.
user_pref("breakpad.reportURL", "");
user_pref("browser.tabs.crashReporting.sendReport", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);

// No experiments / Shield studies.
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("app.normandy.enabled", false);
user_pref("app.normandy.api_url", "");
user_pref("messaging-system.rsexperimentloader.enabled", false);

// No Pocket.
user_pref("extensions.pocket.enabled", false);

// No Firefox Accounts / Sync.
user_pref("identity.fxaccounts.enabled", false);

// -----------------------------------------------------------------------------
// 5. BEARBLOCKER — native adblock-rust content classifier
// Same lists as human-secure; agent traffic must not reach ad/tracker networks
// regardless of what the orchestrating agent requests.
// Receipt generation is enabled via bearbrowser.runtime.agent below so every
// block event is logged to bearblocker-receipts.jsonl for audit.
// -----------------------------------------------------------------------------
user_pref("privacy.trackingprotection.content.protection.enabled", true);
user_pref("privacy.trackingprotection.content.protection.test_list_urls", "resource://bearblocker/bearblocker-ads.txt|resource://bearblocker/bearblocker-privacy.txt");
// Cosmetic filtering runs in content process — useful even for headless sessions
// because it prevents ad layout from consuming CPU or triggering layout reflows
// that would otherwise affect timing-based automation.
user_pref("bearbrowser.bearblocker.cosmetic.enabled", true);

// -----------------------------------------------------------------------------
// 6. RUNTIME IDENTITY — declares this session as agent-runtime to in-browser
// code (BearBlockerPolicy, hold-queue bridge, future governance integrations).
// -----------------------------------------------------------------------------
// Tells BearBlockerPolicy to generate receipts for every block event.
user_pref("bearbrowser.runtime.agent", true);
// Disables interactive DevTools attach via ThreadActor (CDP remote debugging
// used by Playwright/WebDriver is unaffected — it bypasses ThreadActor).
// Prevents a malicious page script from attaching a JS debugger to the agent session.
user_pref("bearbrowser.debugger.force_detach", true);
// Silence console API events to the interactive console; CDP log listeners are
// separate and remain functional.
user_pref("bearbrowser.console.logging_disabled", true);

// BearNav and BearSponsor are human UX features — disable for agent sessions.
user_pref("bearbrowser.nav.keyboard.enabled", false);
user_pref("bearbrowser.sponsorblock.enabled", false);

// ── Phone-home lockdown (hardening pass 2026-07-29) ──────────────────────────
// Firefox still reaches out to Mozilla/Google on startup + during use even with
// telemetry off. Observed LIVE in the Browser Console: a cleartext hit to
// detectportal.firefox.com on every launch (captive-portal check). Shut the
// whole class down.
user_pref("network.captive-portal-service.enabled", false); // no detectportal.firefox.com
user_pref("captivedetect.canonicalURL", "");
user_pref("network.connectivity-service.enabled", false);   // no connectivity beacons
user_pref("dom.private-attribution.submission.enabled", false); // Firefox PPA ad-attribution (ON by default)
user_pref("browser.discovery.enabled", false);              // addon "discovery" phones home
user_pref("browser.region.network.url", "");                // no region geo-lookup to Mozilla
user_pref("browser.region.update.enabled", false);
user_pref("beacon.enabled", false);                         // navigator.sendBeacon tracking
user_pref("toolkit.coverage.endpoint.base", "");            // coverage telemetry endpoint
user_pref("toolkit.telemetry.server", "");                  // belt-and-suspenders: no telemetry sink
user_pref("geo.provider.network.url", "");                  // no Google geolocation endpoint

// ── Content attack-surface lockdown (measured 2026-07-29) ────────────────────
// Found by scripts/audit/surface-audit.html running in REAL CONTENT SCOPE against
// the shipped build. Each pref below closes a surface the audit proved was open
// to any website. Re-run the audit after changing these.
user_pref("dom.webgpu.enabled", false);        // WebGPU: adapter/limits/features = huge new FP surface (WebGL ctx was already blocked; this was the hole left open)
user_pref("dom.webmidi.enabled", false);       // WebMIDI: device enumeration + fingerprint
user_pref("midi.enabled", false);
user_pref("dom.maxHardwareConcurrency", 2);    // audit leaked the REAL core count (8); pin to 2 like Tor
user_pref("privacy.globalprivacycontrol.enabled", true);              // GPC: legally-meaningful opt-out signal (was OFF)
user_pref("privacy.globalprivacycontrol.functionality.enabled", true);
user_pref("privacy.globalprivacycontrol.pbmode.enabled", true);
user_pref("privacy.donottrackheader.enabled", true);
user_pref("media.webspeech.synth.enabled", false);  // installed voice list = strong per-machine fingerprint

// ── Mozilla RemoteSettings junk + hardcoded-endpoint features ────────────────
// From a live console capture: the RS client attempts ~60 collection syncs per
// launch. Many are Mozilla product junk, and some features hardcode the server
// URL so NO pref can stop them. Kill the features themselves.
//
// 🔴 Translations hardcodes https://firefox.settings.services.mozilla.com/v1 in
// SIX places in TranslationsParent.sys.mjs (+ AppConstants). It is also the
// actor throwing "already registered" on every start. Turn the feature off.
user_pref("browser.translations.automaticallyPopup", false);
user_pref("browser.translations.select.enable", false);
// Pioneer / Rally = Mozilla data-DONATION study programs. Never.
user_pref("toolkit.telemetry.pioneerId", "");
// In-product advertising: CFR recommendations, sponsored suggest, What's New.
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
// Content "personality"/relevance profiling models for newtab.
user_pref("browser.newtabpage.activity-stream.discoverystream.enabled", false);
user_pref("browser.newtabpage.activity-stream.discoverystream.personalization.enabled", false);
// Mozilla VPN / Monitor upsell surfaces.
user_pref("browser.contentblocking.report.monitor.enabled", false);
user_pref("browser.contentblocking.report.vpn.enabled", false);
user_pref("browser.contentblocking.report.hide_vpn_banner", true);
// NOTE (deliberate, do NOT "fix" without deciding): services.settings.server is
// left ALONE. security.pki.crlite_mode=2 (enforcing) gets certificate-revocation
// data via RemoteSettings; blanking the server would silently degrade TLS
// revocation. That is a privacy-vs-security trade to make consciously, not by
// accident. See docs/vendored-supply-chain-audit.md.

// ── Out-of-band Mozilla update channels (MISSED until Michael spotted it) ────
// Caught live in the console:
//   https://aus5.mozilla.org/update/3/GMP/150.0.1-1/20260721203120/
//     Darwin_aarch64-gcc3/en-US/default/Darwin%2025.3.0/default/default/update.xml
// These survive --disable-updater because GMP/DRM and system add-ons are
// SEPARATE channels. The URL templates are fingerprint-bearing BY CONSTRUCTION:
// %VERSION%/%BUILD_ID%/%BUILD_TARGET%/%LOCALE%/%CHANNEL%/%OS_VERSION% — i.e.
// every check tells Mozilla the exact OS version, CPU arch and build.
user_pref("media.gmp-manager.url", "");
user_pref("media.gmp-manager.url.override", "data:text/plain,");
user_pref("media.gmp-manager.updateEnabled", false);
user_pref("media.gmp-manager.cert.requireBuiltIn", false);
user_pref("media.gmp-manager.checkAllPluginsForUpdates", false);
user_pref("media.gmp-widevinecdm.enabled", false);   // Google Widevine DRM blob
user_pref("media.gmp-widevinecdm.visible", false);
user_pref("media.gmp-gmpopenh264.enabled", false);   // Cisco OpenH264 blob
// 🔴 System add-ons = Mozilla silently pushing NEW CODE into the browser
// out-of-band. Unacceptable in a sovereign build.
user_pref("extensions.systemAddon.update.url", "");
user_pref("extensions.systemAddon.update.enabled", false);
// Browser updater (already --disable-updater at build time; belt and braces).
user_pref("app.update.url", "");
user_pref("app.update.enabled", false);
user_pref("app.update.auto", false);
user_pref("app.update.background.scheduling.enabled", false);
// NOTE (deliberate): extensions.update.* is LEFT ALONE. It points at
// versioncheck.addons.mozilla.org and is how installed add-ons receive SECURITY
// updates. Blanking it would silently freeze add-ons on vulnerable versions —
// a security regression bought with privacy. Conscious decision, same as
// services.settings.server. See docs/vendored-supply-chain-audit.md.

// ── Mozilla-INDEPENDENT security + on-disk residue ──────────────────────────
// These need nobody's server. Free wins we were leaving on the table.
user_pref("security.mixed_content.block_active_content", true);
user_pref("security.mixed_content.block_display_content", true);
// AboutHomeStartupCache writes your home/newtab CONTENT to disk so startup looks
// fast. That is forensic residue on a privacy browser (and the source of the
// "requestCache called with no _procManager" console spam). Off.
user_pref("browser.startup.homepage.abouthome_cache.enabled", false);
// Sponsored/"frecency-boosted" newtab surfaces (RS collection
// main/newtab-frecency-boosted-sponsors was still being requested).
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories.options", "{}");
user_pref("browser.newtabpage.activity-stream.default.sites", "");
// NOTE on security.OCSP.require: deliberately left FALSE. Hard-failing when an
// OCSP responder is unreachable breaks browsing on flaky networks, and
// revocation is already covered by CRLite (security.pki.crlite_mode=2,
// enforcing). If we ever lose CRLite data, flip this to true — see
// docs/sovereign-remote-settings-mirror.md.

// ── URL bar: remove vendor presets + typo/prefetch leaks ────────────────────
// Michael spotted Mozilla's preset shortcuts (Wikipedia / YouTube / AP News /
// Reddit) sitting in a FRESH profile's address bar. We never chose those, and
// one fat-finger loads a site the user never asked for.
user_pref("browser.urlbar.suggest.topsites", false);   // the preset dropdown
user_pref("browser.topsites.useRemoteSetting", false); // stop pulling tiles from RemoteSettings
user_pref("browser.newtabpage.activity-stream.feeds.system.topsites", false);
// 🔴 Typo + prefetch leaks — these contact hosts you never intended:
//   speculativeConnect  opens TCP to an autocomplete GUESS before you hit enter
//   fixup.alternate     turns a typo like "gogle" into "www.gogle.com" and
//                       resolves/connects to it
//   dnsResolveFullyQualifiedNames  DNS lookups while you are still typing
user_pref("browser.fixup.alternate.enabled", false);
user_pref("browser.urlbar.dnsResolveFullyQualifiedNames", false);
// keyword.enabled=false: a bare non-URL string in the address bar is NOT silently
// handed to a search engine. Deliberate: the user chooses when to search.
user_pref("keyword.enabled", false);
