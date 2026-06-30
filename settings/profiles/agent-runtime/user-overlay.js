// =============================================================================
// BearBrowser agent-runtime overlay preferences
// =============================================================================
// Layered ON TOP of the 101-pref fingerprinting shield (profiles/default/user.js)
// and the agent-runtime baseline (settings/profiles/agent-runtime/user.js).
// This overlay enables the loopback, token-gated WebDriver-BiDi control surface
// for the agent-control bridge (docs/agent-control-bridge.md) and disables the
// interactive prompts that would otherwise block headless automation — WITHOUT
// weakening the shield. The page still sees a normal Firefox-ESR-cohort browser
// (fingerprinting posture: spoof-normality).
//
// HONESTY NOTE: runtime binding pending the LibreWolf binary build. These prefs
// describe the intended agent-runtime posture; they are not yet active in a
// running browser process.
//
// Governance: policy/bearbrowser-contract.yaml
//   (agentRuntime.devtools.remoteDebugging: bindAddress 127.0.0.1,
//    requireEphemeralPort, requireSessionToken, default deny / opt-in per session)
// =============================================================================

// ── WebDriver-BiDi / Remote Agent control surface (loopback-only) ────────────
// Gecko-native automation protocol. OFF by default at the profile level; the
// bridge launches with the runtime flag per session and binds to an ephemeral
// loopback port behind a per-session token. We pin the protocol to BiDi.
user_pref("remote.active-protocols", 1);                 // 1 = WebDriver-BiDi only (not CDP)
user_pref("remote.enabled", false);                      // off by default; bridge opts in per session
user_pref("remote.force-local", true);                   // refuse non-loopback binds
user_pref("marionette.port", 0);                         // 0 = ephemeral port chosen at launch
user_pref("remote.log.level", "Info");

// ── Suppress prompts that block unattended automation ────────────────────────
// These do NOT touch the fingerprint surface; they remove blocking modals.
user_pref("dom.disable_beforeunload", true);             // no "leave page?" modal
user_pref("dom.disable_open_during_load", true);         // suppress popups during load
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.warnOnCloseOtherTabs", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("app.update.auto", false);                     // no update prompts mid-session
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.aboutConfig.showWarning", false);

// ── Downloads: gated + quarantined (see mounts/agent-browser-mounts.yaml) ─────
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.dir", "/workspace/downloads");
user_pref("browser.download.folderList", 2);             // 2 = use browser.download.dir
user_pref("browser.download.always_ask_before_handling_new_types", false);
user_pref("browser.download.manager.addToRecentDocs", false);
// A downloaded file is never auto-opened/executed (quarantine; gated promotion).
user_pref("browser.helperApps.deleteTempFileOnExit", true);

// ── Sensitive surfaces default-DENIED (gated/prohibited in the contract) ──────
user_pref("signon.rememberSignons", false);              // agent never stores/enters credentials
user_pref("signon.autofillForms", false);
user_pref("extensions.formautofill.creditCards.enabled", false);
user_pref("extensions.formautofill.addresses.enabled", false);
user_pref("media.navigator.enabled", false);             // camera/mic gated
user_pref("geo.enabled", false);                         // geolocation gated
user_pref("dom.w3c_pointer_events.enabled", true);

// ── KEEP the shield (spoof-normality, ride the ESR cohort) ───────────────────
// Re-assert the load-bearing anti-fingerprinting prefs so this overlay can never
// silently weaken them. Source of truth remains profiles/default/user.js (101).
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.firstparty.isolate", true);           // first-party isolation ON
user_pref("privacy.resistFingerprinting.reduceTimerPrecision.unconditional", true);
// Hide automation markers so the page cannot tell this is an agent rig.
user_pref("dom.webdriver.enabled", false);               // navigator.webdriver = false
user_pref("toolkit.telemetry.enabled", false);           // no telemetry egress
