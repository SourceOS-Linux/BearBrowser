// BearBrowser human-secure profile preferences.
// Applied on top of LibreWolf defaults. Values here take precedence.
// Do not add agent-runtime concerns to this file — see profiles/agent-runtime/user.js.

// ── DNS-over-HTTPS (Quad9, strict) ────────────────────────────────────────────
// Quad9 (Swiss non-profit foundation, GDPR jurisdiction) is preferred over
// Cloudflare: no commercial data incentive, and — critically — Quad9 does NOT
// forward EDNS Client Subnet (RFC 7871) to authoritative servers, so it
// structurally leaks less of the client than ECS-forwarding resolvers do.
//   9.9.9.9  = filtered (malware/phishing block + DNSSEC validation, NO ECS) ← used
//   9.9.9.10 = unfiltered, no DNSSEC, NO ECS   (swap the IP below to opt out of filtering)
//   9.9.9.11 = block + DNSSEC + ECS-FORWARDING (do NOT use — leaks subnet)
// Mode 3 = TRR-only, hard-fail: Firefox never silently falls back to plaintext
// system DNS for web traffic (only captive-portal/bootstrap probes use native DNS).
user_pref("network.trr.mode", 3);
// IP-form DoH URL: Quad9's TLS cert SAN includes the anycast IP, so no bootstrap
// hostname lookup is needed (same pattern as the prior 1.1.1.1 config).
// NOTE: the previous config set network.trr.bootstrapAddress — a pref REMOVED in
// Firefox 89 (bug 1703216; renamed to network.trr.bootstrapAddr). It was a silent
// no-op. Dropped entirely here since IP-form DoH requires no bootstrap.
user_pref("network.trr.uri", "https://9.9.9.9/dns-query");
user_pref("network.trr.custom_uri", "https://9.9.9.9/dns-query");
user_pref("network.trr.confirmationNS", "skip");
// Suppress EDNS Client Subnet on the wire (scope /0) — defense-in-depth on top
// of Quad9 already not forwarding it (RFC 7871).
user_pref("network.trr.disable-ECS", true);
// DNS-rebinding guard: reject RFC1918/private-IP answers from the resolver so a
// hostile/compromised resolver can't map a public name onto an internal host.
user_pref("network.trr.allow-rfc1918", false);
// Do not send a User-Agent or other identifying headers to the DoH resolver.
user_pref("network.trr.send_user-agent-headers", false);
// EDNS(0) message padding (RFC 8467) to blunt size-based query analysis.
user_pref("network.trr.padding", true);

// ── Google Safe Browsing — belt-and-suspenders removal ───────────────────────
// LibreWolf strips this at build time; these prefs ensure it stays off even if
// an upstream update re-enables it.
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("browser.safebrowsing.blockedURIs.enabled", false);
user_pref("browser.safebrowsing.downloads.enabled", false);
user_pref("browser.safebrowsing.downloads.remote.enabled", false);
user_pref("browser.safebrowsing.provider.google4.updateURL", "");
user_pref("browser.safebrowsing.provider.google4.gethashURL", "");
user_pref("browser.safebrowsing.provider.google.updateURL", "");
user_pref("browser.safebrowsing.provider.google.gethashURL", "");
user_pref("browser.safebrowsing.provider.mozilla.updateURL", "");
user_pref("browser.safebrowsing.provider.mozilla.gethashURL", "");

// ── Fingerprinting resistance ─────────────────────────────────────────────────
// LibreWolf enables privacy.resistFingerprinting by default; reinforce here.
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.letterboxing", true);
user_pref("webgl.disabled", false);
user_pref("webgl.enable-webgl2", true);
// Canvas randomization is always-on under RFP since Firefox bug 1816189
// (the former privacy.resistFingerprinting.randomDataOnCanvasExtract pref was
// removed in bug 1670447). No explicit pref needed — RFP injects per-session
// canvas noise automatically. Do not re-add a manual canvas pref; it is a no-op.

// ── Accept-Language / locale normalization ────────────────────────────────────
// The HTTP Accept-Language header is sent on every request before JS runs and
// exposes the OS locale at the network level. RFP normalizes it to en-US; these
// prefs make that explicit and immune to reset. intl.accept_languages also
// controls Intl API resolvedOptions() locale output in JS.
user_pref("intl.accept_languages", "en-US, en");
user_pref("javascript.use_us_english_locale", true);

// ── Engine-level font and timer fingerprinting protection ─────────────────────
// layout.css.font-visibility controls which fonts are visible to CSS local()
// resolution in gfxPlatformFontList. 2=base system fonts only (blocks installed
// font enumeration via @font-face timing attacks). 1=hidden in private windows.
// Covers the C++ layout path that JS document.fonts.check() overriding misses.
user_pref("layout.css.font-visibility.standard", 2);
user_pref("layout.css.font-visibility.private", 1);
user_pref("layout.css.font-visibility.trackingprotection", 2);
// ── Bundled-font allowlist (the real font-fingerprint fix) ───────────────────
// font-visibility alone is insufficient — measured: 13/14 macOS system fonts
// stay detectable at every level. The strong lever is font.system.whitelist,
// Gecko's built-in anti-fingerprint allowlist: gfxPlatformFontList::ApplyWhitelist
// filters the installed family list to ONLY these names, so web content can't
// enumerate any other font. Empirically verified to drop detection 13/14 -> 0/14.
// We ship metric-compatible bundled fonts (Arimo=Arial, Tinos=Times, Cousine=
// Courier) and whitelist exactly those, so every OS exposes the SAME font set —
// cross-platform uniformity, the Tor/Mullvad approach.
// SAFETY: if none of the whitelisted families are present (e.g. bundling not yet
// active in a dev build), ApplyWhitelist ignores the list (no zero-font browser).
user_pref("gfx.bundled-fonts.activate", 1);
user_pref("font.system.whitelist", "Arimo, Tinos, Cousine");
// Map the CSS generics onto the bundled families so serif/sans-serif/monospace
// resolve identically everywhere (and don't fall back oddly under the whitelist).
user_pref("font.name.serif.x-western", "Tinos");
user_pref("font.name.sans-serif.x-western", "Arimo");
user_pref("font.name.monospace.x-western", "Cousine");
user_pref("font.default.x-western", "sans-serif");
// Timer precision: 1000µs (1ms) granularity via nsRFPService — covers main
// thread, Web Workers, and compositor rAF callbacks from a single C++ call site.
user_pref("privacy.resistFingerprinting.reduceTimerPrecision", true);
user_pref("privacy.resistFingerprinting.reduceTimerPrecision.microseconds", 1000);

// ── Tracker and content blocking ─────────────────────────────────────────────
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);
user_pref("privacy.trackingprotection.cryptomining.enabled", true);
user_pref("privacy.trackingprotection.fingerprinting.enabled", true);
user_pref("privacy.trackingprotection.emailtracking.enabled", true);
user_pref("browser.contentblocking.category", "strict");

// ── Cookie isolation (dFPI — Dynamic First-Party Isolation) ──────────────────
// Firefox 86+ dFPI replaces the older firstparty.isolate flag.
user_pref("privacy.partition.network_state", true);
// Also partition the OCSP response cache by first party (parity with agent-runtime)
// so revocation lookups can't be used as a cross-site cache identifier.
user_pref("privacy.partition.network_state.ocsp_cache", true);
user_pref("privacy.partition.serviceWorkers", true);
user_pref("privacy.partition.bloburl_by_registrable_domain", true);
// Third-party cookies blocked entirely.
user_pref("network.cookie.cookieBehavior", 5);
user_pref("network.cookie.sameSite.noneRequiresSecure", true);

// ── WebRTC IP leak protection ────────────────────────────────────────────────
// Do not expose local IP addresses through WebRTC ICE candidates.
user_pref("media.peerconnection.ice.default_address_only", true);
user_pref("media.peerconnection.ice.no_host", true);

// ── Telemetry — belt-and-suspenders ──────────────────────────────────────────
// LibreWolf disables most of this at build time; keep them off via prefs too.
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.server", "");
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);

// ── New tab: kill all sponsored content, Pocket, and news feed ───────────────
user_pref("browser.newtabpage.enabled", true);
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.newtabpage.activity-stream.default.sites", "");
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
user_pref("browser.newtabpage.activity-stream.feeds.snippets", false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.newtabpage.activity-stream.feeds.highlights", false);
user_pref("browser.newtabpage.activity-stream.feeds.discoverystreamfeed", false);
user_pref("browser.newtabpage.activity-stream.discoverystream.enabled", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includePocket", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includeBookmarks", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includeDownloads", false);
user_pref("browser.newtabpage.activity-stream.section.highlights.includeVisited", false);
user_pref("browser.newtabpage.activity-stream.weather.query", "");
user_pref("browser.newtabpage.activity-stream.weatherWidget.enabled", false);
user_pref("browser.newtabpage.activity-stream.system.showWeather", false);
user_pref("browser.newtabpage.activity-stream.showWeather", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
// Pocket
user_pref("extensions.pocket.enabled", false);
user_pref("extensions.pocket.api", "");
user_pref("extensions.pocket.site", "");
// Homepage — BearBrowser start page, packaged into the browser omni.ja at
// browser/bearstart/ (see scripts/bearbrowser-patches.py) so the same URL works
// on Linux/Windows/macOS regardless of install location. (The old value was the
// native-shell's absolute /Applications file path — macOS-only and dead.)
// New-tab uses the same page via settings/start/bearstart-autoconfig.js —
// browser.newtab.url was removed from Firefox years ago and did nothing.
user_pref("browser.startup.homepage", "resource:///bearstart/bearbrowser-start.html");
user_pref("browser.startup.page", 1);

// ── Search engine ─────────────────────────────────────────────────────────────
// Remove Google as a preset and default to a privacy-respecting engine.
// The actual engine list is managed via policies.json; these prefs suppress
// Google re-appearing after updates.
user_pref("browser.search.suggest.enabled", false);
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.search.separatePrivateDefault", true);
user_pref("browser.search.separatePrivateDefault.ui.enabled", true);

// ── Location and sensors ──────────────────────────────────────────────────────
user_pref("geo.enabled", false);
user_pref("geo.provider.network.url", "");
user_pref("device.sensors.enabled", false);

// ── Form and login data ───────────────────────────────────────────────────────
user_pref("signon.rememberSignons", false);
user_pref("signon.autofillForms", false);
user_pref("browser.formfill.enable", false);
user_pref("extensions.formautofill.creditCards.enabled", false);

// ── Network ───────────────────────────────────────────────────────────────────
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.prefetch-next", false);
user_pref("network.predictor.enabled", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.dns.disablePrefetchFromHTTPS", true);
// Accept-Language: RFP normalizes this to en-US,en;q=0.5 when
// privacy.resistFingerprinting=true. Make it explicit.
user_pref("network.http.accept-language", "en-US,en;q=0.5");
// HTTP/2 and HTTP/3 header ordering is normalized by Firefox's network stack
// when RFP is active; these prefs ensure the order is deterministic.
user_pref("network.http.http2.enabled", true);
user_pref("network.http.http3.enable", true);
// Suppress network-layer connection coalescing leaks
user_pref("network.http.altsvc.enabled", false);
user_pref("network.http.altsvc.oe", false);
// HTTP/3 discovery: with Alt-Svc disabled above, HTTP/3 is advertised to us only
// via DNS HTTPS/SVCB resource records (RFC 9460). Keep that path on, and let the
// same HTTPS RR drive HTTP->HTTPS upgrades.
user_pref("network.dns.use_https_rr_as_altsvc", true);
user_pref("network.dns.upgrade_with_https_rr", true);
// Encrypted ClientHello (ECH): the HTTPS RR can carry an ECHConfig that encrypts
// SNI — closing the last cleartext leak of which host you're visiting. Strict
// upside: opportunistic, so sites without an ECHConfig still use cleartext SNI,
// but a published ECHConfig is never silently downgraded.
user_pref("network.dns.echconfig.enabled", true);
user_pref("network.dns.http3_echconfig.enabled", true);

// ── HTTPS-Only mode ───────────────────────────────────────────────────────────
user_pref("dom.security.https_only_mode", true);
user_pref("dom.security.https_only_mode_send_http_background_request", false);

// ── Media autoplay ────────────────────────────────────────────────────────────
user_pref("media.autoplay.default", 5);
user_pref("media.autoplay.blocking_policy", 2);

// ── Certificate / TLS hardening ───────────────────────────────────────────────
// Refuse TLS handshakes that use legacy (unsafe) renegotiation. Sites that
// require it are either misconfigured or actively downgrading security.
user_pref("security.ssl.require_safe_negotiation", true);
user_pref("security.ssl.treat_unsafe_negotiation_as_broken", true);
// TLS 1.2 minimum (value 3 = TLS 1.2; Firefox 78+ ships with this default but
// this pref makes it explicit and immune to policy resets).
user_pref("security.tls.version.min", 3);
// OCSP: check certificate revocation status on every TLS connection.
// require=false avoids hard failures when an OCSP responder is unavailable
// (soft-fail is standard practice; hard-fail breaks too many sites on flaky
// networks while providing marginal extra security over CRLite).
user_pref("security.OCSP.enabled", 1);
user_pref("security.OCSP.require", false);
// Enforce built-in certificate pins strictly (level 2). Prevents MITM against
// pinned properties even if a rogue CA is in the trust store.
user_pref("security.cert_pinning.enforcement_level", 2);
// CRLite mode 2: use the pre-downloaded CRL bloom filter for revocation checks.
// Faster and more reliable than OCSP alone; doesn't leak visited sites to OCSP
// responders.
user_pref("security.pki.crlite_mode", 2);

// ── Media / hardware fingerprinting ──────────────────────────────────────────
// Suppress video decode statistics exposed via HTMLVideoElement.getVideoPlaybackQuality.
// These stats vary by GPU/driver and form a fingerprinting vector.
user_pref("media.video_stats.enabled", false);
// Prevent sites from enumerating cameras and microphones without an explicit
// permission grant. The devices are still fully usable once the user approves.
user_pref("media.navigator.enabled", false);
// Disable DRM (Encrypted Media Extensions) by default. Users who need Widevine
// for a specific site can re-enable via about:preferences or a site permission.
// Widevine involves a closed-source binary blob with unclear data practices.
user_pref("media.eme.enabled", false);
// Disable the GMP (Gecko Media Plugin) provider that auto-downloads Widevine.
// Without EME enabled this is redundant, but belt-and-suspenders.
user_pref("media.gmp-provider.enabled", false);
// MSE (Media Source Extensions) left enabled — disabling breaks YouTube,
// Twitch, and virtually every major streaming site.
user_pref("dom.media.mediasource.enabled", true);

// ── Site isolation (Fission) ──────────────────────────────────────────────────
// Fission puts each site origin in its own OS process, preventing cross-site
// data leaks via Spectre-class side-channels. Enabled by default in Firefox 95+
// but explicit here so a downstream patch can't silently roll it back.
user_pref("fission.autostart", true);
// Ensure privileged Mozilla content (about:*, AMO, etc.) gets its own separate
// process, isolated from regular web content.
user_pref("browser.tabs.remote.separatePrivilegedMozillaWebContentProcess", true);

// ── Push / notification background connection ─────────────────────────────────
// Disable the persistent WebPush connection to Mozilla's push service. Push
// notifications still work when the user explicitly grants permission per-site,
// but the background TCP connection is severed at rest. Reduces idle network
// fingerprinting surface and eliminates a persistent connection to Mozilla infra.
user_pref("dom.push.connection.enabled", false);

// ── Referer / network anti-fingerprinting ─────────────────────────────────────
// RFP already strips most referer leakage, but these prefs apply independently
// (e.g. for users who disable RFP for usability) and make intent explicit.
// 2 = send referer header (required for many sites); defaultPolicy controls
// what is sent. strict-origin-when-cross-origin (2) = send full URL same-origin,
// origin-only cross-origin, nothing cross-scheme. Matches Chrome's default.
user_pref("network.http.sendRefererHeader", 2);
user_pref("network.http.referer.defaultPolicy", 2);
user_pref("network.http.referer.defaultPolicy.pbmode", 2);
// Trim cross-origin referers to scheme+host+port (drop path/query). This is a
// genuinely additive hardening NOT covered by RFP — matches the arkenfox
// baseline and removes per-page referer granularity on cross-origin requests.
user_pref("network.http.referer.XOriginTrimmingPolicy", 2);
// Show raw punycode for IDN domains in the address bar. Prevents IDN homograph
// attacks where visually identical Unicode characters substitute for ASCII
// (e.g. аpple.com with Cyrillic а).
user_pref("network.IDN_show_punycode", true);

// ── BearBlocker — native adblock-rust content classifier ─────────────────────
// ContentClassifierService uses the compiled adblock-rust engine (same one Brave
// uses) to block ad and tracker network requests at the C++ network layer before
// any JS runs. Filter lists are bundled in the browser at resource://bearblocker/
// and loaded at startup. No extension process, no user-visible install.
//
// Cosmetic rules (CSS injection to hide ad placeholder elements) are applied by
// the BearBlockerChild JSWindowActor registered in DesktopActorRegistry.
user_pref("privacy.trackingprotection.content.protection.enabled", true);
user_pref("privacy.trackingprotection.content.protection.test_list_urls", "resource://bearblocker/bearblocker-ads.txt|resource://bearblocker/bearblocker-privacy.txt");
// Cosmetic filtering (CSS injection for leftover ad placeholders)
user_pref("bearbrowser.bearblocker.cosmetic.enabled", true);

// ── Crash reporting (belt-and-suspenders) ─────────────────────────────────────
// LibreWolf disables crash reporting at build time. These prefs ensure any
// upstream patch or a stock Firefox build never silently re-enables it.
user_pref("breakpad.reportURL", "");
user_pref("browser.tabs.crashReporting.sendReport", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);

// ── Experiments / studies (belt-and-suspenders) ───────────────────────────────
// Belt-and-suspenders alongside DisableFirefoxStudies in policies.json.
// These prefs cover older Firefox experiment infrastructure not gated by that
// policy key.
user_pref("experiments.activeExperiment", false);
user_pref("experiments.enabled", false);
user_pref("experiments.supported", false);
user_pref("network.allow-experiments", false);

// ── Misc DOM hardening ────────────────────────────────────────────────────────
// Prevent scripts from programmatically closing browser windows they did not
// open. Commonly abused by pop-under ad networks.
user_pref("dom.allow_scripts_to_close_windows", false);
// Honour X-Frame-Options headers. Prevents clickjacking by ensuring the browser
// respects sites that declare they must not be framed.
user_pref("browser.xfocontent", true);
// Allow links that request a new window (target=_blank etc.) to open in a tab
// instead of a separate window. 0 = no restriction; new windows become tabs.
// Improves usability without any privacy regression.
user_pref("browser.link.open_newwindow.restriction", 0);

// ── BearNav — native keyboard navigation ─────────────────────────────────────
// f=link hints, j/k=scroll, d/u=half page, gg=top, G=bottom, H/L=back/forward
user_pref("bearbrowser.nav.keyboard.enabled", true);

// ── BearTrap honeypot suite ──────────────────────────────────────────────────
// Zero-trust detection: bait + catch fingerprinters and exfiltrators. The
// fingerprint honeypot instruments canvas/WebGL/audio/enumeration surfaces and
// flags a page that probes 3+ of them; the canary plants a per-origin decoy
// token and attributes any outbound leak of it. Detection-only — never breaks a
// page. (RFP still spoofs the values; BearTrap tells you WHO tried.)
user_pref("bearbrowser.honeypot.enabled", true);

// ── BearSponsor — native SponsorBlock integration ────────────────────────────
// Skips sponsored segments on YouTube using hash-based SponsorBlock API.
// Only 4 hex chars of SHA-256(videoId) are sent; full ID stays local.
user_pref("bearbrowser.sponsorblock.enabled", true);

// ── Additional fingerprinting hardening (Gecko-specific) ─────────────────────
// These prefs close gaps that the WKWebView JS shield handles for the overlay
// build but that require Gecko prefs for the nightly CI build.

// Gamepad API: exposes controller hardware identifiers (vendor/product IDs)
// and the number/type of connected gamepads.
user_pref("dom.gamepad.enabled", false);
user_pref("dom.gamepad.extensions.enabled", false);
user_pref("dom.gamepad.haptic_actuators.enabled", false);
user_pref("dom.gamepad.non_standard_events.enabled", false);

// WebXR/WebVR: presence of XR hardware is a rare, highly-identifying signal.
user_pref("dom.vr.enabled", false);
user_pref("dom.vr.webxr.enabled", false);

// Keyboard Layout API: getLayoutMap() reveals input language and keyboard type.
user_pref("dom.keyboard.layout_map.enabled", false);

// navigator.plugins — cohort = empty array (length 0), matching Firefox-ESR/Tor
// under RFP. The bundled PDF viewer can surface as pseudo-plugin entries; ensure
// the PDF.js scripting/pseudo-plugin surface is not exposed so the count stays 0.
user_pref("pdfjs.enableScripting", false);

// Extension detection hardening: blocks sites from detecting installed addons
// via WebExtension API reflection.
user_pref("privacy.resistFingerprinting.block_mozAddonManager", true);

// CSS media feature normalization: force light color scheme so prefers-color-scheme
// queries reflect a fixed, non-identifying value.
user_pref("ui.systemUsesDarkTheme", 0);
user_pref("layout.css.prefers-color-scheme.content-override", 1);

// Reduce motion / contrast queries: normalize to "no preference" baseline.
user_pref("ui.prefersReducedMotion", 0);
user_pref("ui.useAccessibilityTheme", 0);

// NOTE: devicePixelRatio normalization is owned by RFP. We deliberately do NOT
// set layout.css.devPixelsPerPx — hardcoding it (e.g. to "2.0", a value that
// leaked over from the WKWebView JS shield) forces a 2x render scale on
// non-Retina/external displays and desyncs from RFP's own DPR rounding, making
// the browser MORE fingerprintable, not less. Let RFP handle it.

// TLS ceiling: offer only TLS 1.2/1.3 so our ClientHello cipher suite list
// matches the narrow modern-browser set, minimizing JA3 distinctiveness.
user_pref("security.tls.version.max", 4);

// HTTP/3/QUIC: left ENABLED (see network.http.http3.enable above). Disabling it
// would make this browser rarer than the QUIC-speaking majority — the opposite
// of blending in — and costs performance, while RFP does not require it. Tor
// Browser likewise does not disable HTTP/3. A prior line here set the misspelled
// pref `network.http.http3.enabled` (trailing 'd'), which is non-existent and was
// a silent no-op; removed to eliminate the contradiction.

// ── QUIC / TLS cross-connection supercookie protection ───────────────────────
// With HTTP/3 + DoH on, the real cross-connection tracking vectors are server-
// issued, client-replayed opaque blobs that act as supercookies:
//   - QUIC NEW_TOKEN address-validation tokens (RFC 9000 §8.1/§19.7/§21)
//   - TLS 1.3 / QUIC 0-RTT session tickets / PSK (RFC 9001 §4.6, RFC 8446 §C.4)
// The DECISIVE mitigation is privacy.partition.network_state (set true above),
// which partitions the connection pool, TLS tickets, 0-RTT state AND the QUIC
// NEW_TOKEN store by first-party site — so a tracker present on two sites gets
// different token/ticket state and cannot link the visits. (Note: RFP does NOT
// cover any of this; it is purely the partitioning + security.tls prefs.)
// Defense-in-depth: disable 0-RTT early data. 0-RTT's added risk over normal
// resumption is replay (RFC 8446 §8); the linkable identifier is the ticket
// itself, which partitioning already isolates. Disabling early data is a
// conservative hardening with near-zero downside (slight resumption latency).
user_pref("security.tls.enable_0rtt_data", false);

// ── Phone-home lockdown (hardening pass 2026-07-29) ──────────────────────────
// Firefox still reaches out to Mozilla/Google on startup + during use even with
// telemetry off. Observed LIVE in the Browser Console: a cleartext hit to
// detectportal.firefox.com on every launch (captive-portal check). Shut the
// whole class down.
user_pref("network.captive-portal-service.enabled", false); // no detectportal.firefox.com
user_pref("captivedetect.canonicalURL", "");
user_pref("network.connectivity-service.enabled", false);   // no connectivity beacons
user_pref("dom.private-attribution.submission.enabled", false); // Firefox PPA ad-attribution (ON by default)
user_pref("app.normandy.enabled", false);                   // Mozilla remote experiments
user_pref("app.normandy.api_url", "");
user_pref("app.shield.optoutstudies.enabled", false);       // Shield studies
user_pref("browser.discovery.enabled", false);              // addon "discovery" phones home
user_pref("browser.region.network.url", "");                // no region geo-lookup to Mozilla
user_pref("browser.region.update.enabled", false);
user_pref("beacon.enabled", false);                         // navigator.sendBeacon tracking
user_pref("toolkit.coverage.endpoint.base", "");            // coverage telemetry endpoint

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
user_pref("dom.webnotifications.enabled", false);   // notification permission prompts = tracking vector
user_pref("dom.webnotifications.serviceworker.enabled", false);
user_pref("dom.push.enabled", false);               // push = persistent re-identification channel

// ── Mozilla RemoteSettings junk + hardcoded-endpoint features ────────────────
// From a live console capture: the RS client attempts ~60 collection syncs per
// launch. Many are Mozilla product junk, and some features hardcode the server
// URL so NO pref can stop them. Kill the features themselves.
//
// 🔴 Translations hardcodes https://firefox.settings.services.mozilla.com/v1 in
// SIX places in TranslationsParent.sys.mjs (+ AppConstants). It is also the
// actor throwing "already registered" on every start. Turn the feature off.
user_pref("browser.translations.enable", false);
user_pref("browser.translations.automaticallyPopup", false);
user_pref("browser.translations.select.enable", false);
// Pioneer / Rally = Mozilla data-DONATION study programs. Never.
user_pref("toolkit.telemetry.pioneerId", "");
// In-product advertising: CFR recommendations, sponsored suggest, What's New.
user_pref("browser.messaging-system.whatsNewPanel.enabled", false);
user_pref("browser.urlbar.quicksuggest.enabled", false);
user_pref("browser.urlbar.suggest.quicksuggest.sponsored", false);
user_pref("browser.urlbar.suggest.quicksuggest.nonsponsored", false);
// Content "personality"/relevance profiling models for newtab.
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
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories.options", "{}");
// NOTE on security.OCSP.require: deliberately left FALSE. Hard-failing when an
// OCSP responder is unreachable breaks browsing on flaky networks, and
// revocation is already covered by CRLite (security.pki.crlite_mode=2,
// enforcing). If we ever lose CRLite data, flip this to true — see
// docs/sovereign-remote-settings-mirror.md.
