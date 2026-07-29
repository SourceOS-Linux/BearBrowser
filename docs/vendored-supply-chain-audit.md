# Vendored supply-chain audit — what we actually ship

Scanned the **shipped** `/Applications/BearBrowser.app` (v150.0.1): 7,160 files
extracted from `omni.ja`, plus the binaries in the bundle. Principle: *we ship
it, we own it* — "that's upstream's code" is not an answer for a sovereign
browser.

## ✅ The telemetry SENDERS are physically absent
The executables that would transmit anything are **not in the bundle**:

| Binary | Status |
|---|---|
| `pingsender` (telemetry ping transmitter) | **absent** |
| `glean` (telemetry SDK binary) | **absent** |
| `crashreporter` | **absent** (`--disable-crashreporter`) |
| `minidump-analyzer` | **absent** |
| `updater` | **absent** (`--disable-updater`) |

Code that isn't there can't run. This is the strongest form of the guarantee —
stronger than a pref, which can be flipped.

⚠️ Note: `crashreporter` being absent is exactly why crashes produced **no
`.ips`, no minidump, nothing**. Re-enabled for mac/linux — submission stays off,
reports stay local.

## ✅ Google/ad hostnames found are ANTI-tracking, not calls
`doubleclick` (28 files), `google-analytics`, `googletagmanager` all resolve to
`chrome/browser/builtin-addons/webcompat/shims/` — Mozilla's **webcompat shims**,
which replace blocked tracker scripts with **local stubs** so sites don't break.
That is tracker-blocking infrastructure. Counting them as "leaks" would be a
false positive.

## ✅ Covered by our prefs (verified present in human-secure)
`extensions.pocket.enabled`, `…showSponsored`, `…showSponsoredTopSites`,
`…feeds.section.topstories`, `browser.safebrowsing.provider.google4.updateURL`,
`toolkit.telemetry.server` — plus the phone-home lockdown (captive portal,
Normandy, PPA, region, beacon, connectivity).

## 🔴 Still shipped, disabled only by PREF (not removed)
These are the real remaining gap — a pref can be flipped, code cannot be unrun:
- **Pocket / sponsored content code**: `spocs.getpocket.com` in
  `builtin-addons/newtab/lib/ActivityStream.sys.mjs` and `DiscoveryStreamFeed.sys.mjs`.
- **Endpoint defaults baked into `greprefs.js` / `defaults/preferences/firefox.js`**:
  `incoming.telemetry`, `detectportal.firefox`, `safebrowsing.googleapis`,
  `contile.services.mozilla` (sponsored tiles), `location.services.mozilla`,
  `push.services.mozilla`, `normandy.cdn`, `firefox.settings.services.mozilla`.

**Recommended next step:** strip the newtab/Pocket/Contile code at *build* time
(package-manifest / moz.build) instead of pref-disabling it, and blank the
endpoint defaults in `greprefs.js` via a patch — so the strings aren't even
present to be re-enabled.

## Method
Reproduce with:

    unzip -qq /Applications/BearBrowser.app/Contents/Resources/browser/omni.ja -d /tmp/omni
    # then grep for endpoint hosts; classify shim/blocklist vs real caller
    find /Applications/BearBrowser.app -iname '*pingsender*' -o -iname '*glean*'

Pair with `scripts/audit/` (runtime content-scope surface) — this doc is the
*static* half, that harness is the *dynamic* half.
