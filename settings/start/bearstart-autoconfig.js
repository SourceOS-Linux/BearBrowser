// BearBrowser start page wiring — appended to bearbrowser.cfg (autoconfig).
// NOTE: autoconfig .cfg files SKIP THEIR FIRST LINE, so when this file becomes
// the whole cfg (macOS post-package injection) the leading comment above is the
// sacrificial line. When appended to the generated cfg (Linux/Windows overlay
// path) position doesn't matter.
//
// There is no pref for the new-tab URL in modern Firefox — the supported
// mechanism is setting AboutNewTab.newTabURL from privileged autoconfig JS
// (requires general.config.sandbox_enabled=false, set in local-settings.js).
// Wrapped so a failure can never break browser startup.
try {
  if (!Services.appinfo.inSafeMode) {
    const { AboutNewTab } = ChromeUtils.importESModule(
      "resource:///modules/AboutNewTab.sys.mjs"
    );
    AboutNewTab.newTabURL = "resource:///bearstart/bearbrowser-start.html";
  }
} catch (e) {
  // Leave stock about:newtab in place rather than risk startup.
}
