# SPEC — Tor-mode OS spoof (force Windows identity for all platforms)

Status: **SPEC, not yet a patch.** This is the single biggest "spoof normality"
lever for Tor mode and it is a *coordinated multi-site* change — a single missed
use-site leaves an INCONSISTENT identity (UA says Windows, `navigator.oscpu` says
Mac), which is MORE fingerprintable than not spoofing at all. For that reason it
is authored against the build with a compiler in the loop, not blind.

## Why a patch and not a pref
Tor Browser makes **every desktop platform report Windows** (`Windows NT 10.0;
Win64; x64`) so Mac/Linux users hide in the Windows majority. Stock Firefox RFP
does NOT do this — it spoofs to the user's *real* OS family. And critically:

> When `privacy.resistFingerprinting=true`, RFP computes its own UA/platform/
> oscpu/appVersion from the compile-time `SPOOFED_*` macros and **ignores**
> `general.useragent.override` / `general.platform.override` / `general.oscpu.override`.

So the override prefs are a no-op here. The OS must be forced at the `nsRFPService`
/ `SPOOFED_*` layer, exactly as Tor does (upstream bugs 1918009 + 42467/42647).

## Target cohort values (Tor Browser 15.0.x / Firefox 140 ESR, Windows branch)
| Surface | Value |
|---|---|
| `navigator.userAgent` + HTTP `User-Agent:` header | `Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0` |
| `navigator.platform` | `Win32` |
| `navigator.oscpu` | `Windows NT 10.0; Win64; x64` |
| `navigator.appVersion` | `5.0 (Windows)` |
| `navigator.buildID` | `20181001000000` (RFP `LEGACY_BUILD_ID`, automatic) |
| `navigator.hardwareConcurrency` | `2` (RFP, automatic) |
| `navigator.maxTouchPoints` | `0` (Tor desktop; our Linux RFP default is 5 → must force 0) |
| `navigator.userAgentData` / `deviceMemory` | `undefined` |
| timezone (`Intl…timeZone`) | `Atlantic/Reykjavik` (RFP, automatic — NOT the literal "UTC") |

## Use-sites to patch (Firefox 150.0.1 tree — verify line numbers at apply time)
The `SPOOFED_*` macros are `#ifdef`-selected compile-time constants in
`toolkit/components/resistfingerprinting/nsRFPService.h:38-60`. Every consumer
must read the SAME runtime decision, or the identity desyncs:

1. `nsRFPService.h:38-60` — keep the per-platform `SPOOFED_*` defaults BUT also
   define always-available Windows constants: `SPOOFED_UA_OS_WIN`,
   `SPOOFED_OSCPU_WIN` = `"Windows NT 10.0; Win64; x64"`, `SPOOFED_APPVERSION_WIN`
   = `"5.0 (Windows)"`, `SPOOFED_PLATFORM_WIN` = `"Win32"`.
2. Add a cached static bool `sSpoofOsToWindows` read from pref
   `bearbrowser.tor-mode.spoof-os == "windows"` (StaticPrefs or a Preferences
   observer; must be readable from the DOM thread + workers).
3. `nsRFPService.cpp:1027,1036` `GetSpoofedUserAgent` — select
   `sSpoofOsToWindows ? SPOOFED_UA_OS_WIN : SPOOFED_UA_OS` for BOTH the
   preallocated length (1027) and the `AppendLiteral` (1036).
4. `dom/base/Navigator.cpp:458` `GetOscpu` — `SPOOFED_OSCPU_WIN` when set.
5. `dom/base/Navigator.cpp:2053` `GetAppVersion` — `SPOOFED_APPVERSION_WIN`.
6. `dom/base/Navigator.cpp` `GetPlatform` — force `Win32` when set (find the
   RFP branch that currently returns the per-OS platform).
7. `dom/workers/WorkerNavigator.cpp:131` `GetAppVersion` (worker) — same.
8. Worker oscpu/platform/UA equivalents — audit `WorkerNavigator.cpp` for every
   `SPOOFED_*` use and gate identically.
9. `maxTouchPoints` — force 0 for the desktop cohort when spoofing (find the
   `SPOOFED_MAX_TOUCH_POINTS` consumer).
10. HTTP header path — confirm `nsHttpHandler` builds its `User-Agent` from
    `GetSpoofedUserAgent` (it does), so #3 covers the header too. VERIFY.

## ⚠️ The residual a Windows-OS spoof does NOT fix: the Firefox VERSION
Our build is **Firefox 150**; the Tor cohort is **140 ESR**. Even with a perfect
OS spoof, our UA reads `Firefox/150.0` while the cohort reads `Firefox/140.0` —
and JS version-probes (feature detection, `navigator.userAgent` parsing) expose
the real engine version. A 150-over-Tor is a *distinct* cohort from 140-over-Tor.

Two ways to close it, both bigger than this patch:
- **(preferred) Build Tor mode on Firefox 140 ESR** — the same train Tor Browser
  rides. Then version, RFP constants, and engine quirks all line up for free.
  This is a build-version decision, tracked in docs/tor-mode.md §version.
- **(risky) Also spoof the version string to 140** — invites detectable
  inconsistencies between the claimed UA and real engine behavior. Not advised.

Until one of those lands, Tor mode delivers FULL network-layer anonymity (the Tor
exit) with a JS identity that is Windows-OS-aligned but **version-distinct**.
Honest framing for the user: the wire is anonymous; the JS blend-in is partial
until we ride the same ESR.
