// BearBrowser human-secure profile preferences.
// Applied on top of LibreWolf defaults. Values here take precedence.
// Do not add agent-runtime concerns to this file — see profiles/agent-runtime/user.js.

// ── DNS-over-HTTPS ────────────────────────────────────────────────────────────
// Mode 3 = strict DoH only; refuse to fall back to plaintext DNS.
user_pref("network.trr.mode", 3);
user_pref("network.trr.uri", "https://1.1.1.1/dns-query");
user_pref("network.trr.bootstrapAddress", "1.1.1.1");
user_pref("network.trr.confirmationNS", "skip");

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
// Randomize canvas — site-specific exceptions are still possible via permissions.
user_pref("privacy.resistFingerprinting.randomDataOnCanvasExtract", true);

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
// Homepage — BearBrowser custom start page
user_pref("browser.startup.homepage", "file:///Applications/BearBrowser.app/Contents/Resources/BearBrowser-start.html");
user_pref("browser.startup.page", 1);
user_pref("browser.newtab.url", "file:///Applications/BearBrowser.app/Contents/Resources/BearBrowser-start.html");

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
// Show raw punycode for IDN domains in the address bar. Prevents IDN homograph
// attacks where visually identical Unicode characters substitute for ASCII
// (e.g. аpple.com with Cyrillic а).
user_pref("network.IDN_show_punycode", true);

// ── BearBlocker — native adblock-rust content classifier ─────────────────────
// ContentClassifierService uses the compiled adblock-rust engine (same one Brave
// uses) to block ad and tracker network requests at the C++ network layer before
// any JS runs. Filter lists are bundled in the browser at resource:///bearblocker/
// and loaded at startup. No extension process, no user-visible install.
//
// Cosmetic rules (CSS injection to hide ad placeholder elements) are applied by
// the BearBlockerChild JSWindowActor registered in DesktopActorRegistry.
user_pref("privacy.trackingprotection.content.protection.enabled", true);
user_pref("privacy.trackingprotection.content.protection.test_list_urls", "resource:///bearblocker/bearblocker-ads.txt|resource:///bearblocker/bearblocker-privacy.txt");
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
