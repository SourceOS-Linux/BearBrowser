# Retrospective — v150.0.1 → v150.0.5

**Author's note.** This document exists because the author (agent + human)
shipped four consecutive releases with defects that were caught only by manual
review after the fact, then declared each release "shipped" as if nothing had
happened. The user's response — "*bullshit, get the branding and polish and
ergonomics and menus and nice-to-haves integrated. also, why did the CI and
continuous build and automated self healing design fail to catch all this? do
a full retrospective on this*" — was correct. What follows is that
retrospective.

## The ten incidents

Every one shipped past CI and was caught by *staring at the diff*, not by an
automated check.

| # | Incident                                                            | Version(s)      | Caught by      |
|---|---------------------------------------------------------------------|-----------------|----------------|
| 1 | `hardwareConcurrency` clamp defeated by Xray wrapper                | v150.0.2–4      | manual review  |
| 2 | Update-check leaked `Referer` + `Cookie` to github.com              | v150.0.5-cand   | manual review  |
| 3 | Semver parser broke on `-rc` suffixes                               | v150.0.5-cand   | manual review  |
| 4 | BearBlocker filter lists shipped with 0 rules                       | weeks           | manual review  |
| 5 | `linux-packaging` silently red on `main` for a week                 | 1 week          | ambient guilt  |
| 6 | Actors alpha-sort `UnsortedError` killed 3 nightlies                | 3 nightlies     | manual review  |
| 7 | `patches.py` `NameError _swept` + malformed `""));` prefs           | pre-merge       | manual review  |
| 8 | RS mirror workflow failed 3× on WIF audience + IAM condition        | v150.0.5-day    | trying it      |
| 9 | Cockpit startup race — tab loaded before sidecar handshake          | pre-fix         | manual repro   |
|10 | Signing pipeline scaffolded, never dry-run tested                   | still           | not caught     |

### 1. Xray-scoped `hardwareConcurrency` clamp

Prefs were set correctly. The clamp was implemented in the privileged actor
scope. Content JS still read `navigator.hardwareConcurrency === 8` because
`Object.getOwnPropertyDescriptor` from privileged code, applied to a content
`navigator`, does not see the getter the clamp thinks it's shadowing — Xray
wrappers hide content-scope properties from chrome code, and vice versa.

**Should have caught it:** `anti-fingerprint.yml` → `harness-and-measure`, but
the harness uses Playwright/Juggler and cannot faithfully exercise the actor
chrome/content boundary. The runtime audit in `nightly-linux.yml` now checks
content-scope `navigator.hardwareConcurrency !== 2` — *added after this
incident*. Was not required for release.

**Fixed here:** promotion gate re-runs `verify-package.sh` against the actual
release artifact (which now grep-asserts the Xray fix keywords in the shipped
`.cfg`) before `publish-latest-json` fires.

### 2. Update-check leaked `Referer` + `Cookie`

The weekly poll of `https://github.com/…/releases/latest/download/latest.json`
was made with a stock `fetch(url)` — sending referrer and any credentials
present. GitHub can now correlate every install to a browsing session cookie.

**Should have caught it:** nothing does. No test exercises the update code
path at all. `verify-package.sh` only checks that legacy Mozilla endpoints are
stripped from prefs, not that outgoing fetches are hygienic.

**Fixed here:**
- `scripts/tests/test_update_check.mjs` asserts the shipped source contains
  `credentials:"omit"` AND `referrerPolicy:"no-referrer"` on the SAME `fetch`
  call (one without the other is still a leak).
- Promotion gate re-asserts both keywords are in the shipped `bearbrowser.cfg`
  before latest.json goes out.
- Adversarial-review checklist in `PULL_REQUEST_TEMPLATE.md` requires this
  for any new fetch/XHR.

### 3. Semver parser broke on `-rc` suffixes

`Number("4-rc1") === NaN`. A pre-release with an `-rc1` suffix would compare
as `NaN > 4` (false) and users would be told "no update".

**Should have caught it:** unit tests on the parser. None existed;
`feature-plane.yml` only runs `py_compile` on Python.

**Fixed here:** `scripts/tests/test_update_check.mjs` has a semver table
including the exact `-rc1` case that failed, plus explicit assertions on
comparison behaviour.

### 4. BearBlocker filter lists shipped with 0 rules

Root cause: `FINAL_TARGET_FILES.bearblocker` (moz.build) does not survive
`mach package` — the packager silently drops the files. The C++
`ContentClassifierService` tried `resource:///bearblocker/…` and 404'd, so
the ad+tracker blocker shipped for weeks with an empty ruleset. Users saw a
"protecting you" indicator that protected nothing.

**Should have caught it:** `scripts/verify-package.sh` was written
specifically for this incident (lines 33–41) and wired into the nightlies.

**Fixed here (belt-and-suspenders):** the promotion gate runs
`verify-package.sh` against the ACTUAL release artifact, not just the nightly
build tree. `linux-packaging.yml` still runs its metadata-only check; the
package-artifact check moves upstream of `publish-latest-json`.

### 5. `linux-packaging` silently red on main for a week

I introduced "LibreWolf-mirror" wording in `packaging/linux/deb/control`.
`verify-linux-packaging.sh` correctly bans that word. The check went red on
`main`. Nothing paged. It stayed red for a week because there was no watchdog
on scheduled or push-workflow red state.

**Should have caught it:** the check DID catch it — the missing piece was
being told about it.

**Fixed here:** `main-branch-red-watchdog.yml` scans every workflow every 3h
and files ONE deduplicated issue if any workflow's last run on `main` has
been red for more than 6 hours. Auto-closes when the estate is green.

### 6. Actors alpha-sort `UnsortedError`

`FINAL_TARGET_FILES.actors += […]` in moz.build requires alphabetical order.
`BearTrap*` must precede `BearVault*` (T < V) and `BearTrapMonitor` must sort
between Child and Parent (M < P). A single out-of-order insert killed the
nightlies; no static check flagged it because the list is *emitted* by
`patches.py`, not stored as source.

**Fixed here:** `scripts/tests/test_bearbrowser_patches.py` rebuilds the
sorted actor list from `settings/actors/*.sys.mjs` on disk and asserts it
matches the literal in `patches.py`. Wired into
`packaging-and-update-tests.yml`.

### 7. `patches.py` `NameError _swept` + malformed pref lines

The URL-host-sweep helper was missing a `nonlocal _swept`. `py_compile`
happily accepts this — Python only surfaces the NameError when the branch
runs. Separately, an errant `))` shipped `""));` into a written pref line
that would have made Firefox refuse the profile.

**Fixed here:** the same `test_bearbrowser_patches.py` imports the module
(triggering top-level defs) and validates every emitted pref line against the
grammar Firefox actually parses. The bug-class comment now lives IN the test
file so a future reader understands why it exists.

### 8. RS mirror WIF failed 3× when I first ran it

Three failures in one hour when we tried to run the mirror workflow with
newly-provisioned secrets: (a) audience mismatch — GCP provider had no
`allowedAudiences`, action sent one form, GCP expected another; (b) I "fixed"
that by setting `allowedAudiences` to a specific value which further
narrowed acceptance and broke; (c) IAM condition scoping `objectAdmin` to
`rs-mirror/**` denied bucket-level `storage.objects.list` which
`gcloud storage rsync` needs. Each attempt burned a real workflow run.

**Should have caught it:** *nothing* did — the scheduled workflow was the
first thing to attempt the auth handshake.

**Fixed here:** `rs-mirror-preflight.yml` runs on ANY change to
`rs-mirror.yml` or `scripts/rs-mirror/**` and exercises exactly the two
operations that failed: `gcloud auth list` (via the `auth@v2` action) and
`gcloud storage ls gs://.../rs-mirror/` + rsync dry-run. Fail-fast in
seconds, in the PR.

### 9. Cockpit startup race

Cockpit tab loaded before the sidecar's `:8080/health` was answering. Fixed
by inserting a waiter page. The fix works; the *test* doesn't exist.

**Fixed here (queued):** the waiter's presence is asserted by
`verify-package.sh:31`. A headless integration test that actually navigates
to the cockpit URL, polls for the ready signal, and fails if the waiter
never resolves — is queued in the follow-ups below. Not landed in this pass.

### 10. Signing pipeline never dry-run tested

Both `sign-and-notarize-macos.yml` and `sign-windows.yml` silently `SKIP=1`
if secrets are absent. Once secrets arrive they'll run in production for the
first time.

**Fixed here (queued):** a rehearsal leg that runs adhoc `codesign --sign -`
on macOS and a locally-generated PFX on Windows is queued below. Not landed
in this pass.

## Systemic gaps and what's fixed

| Gap                                                                     | Landed here                                                                 |
|-------------------------------------------------------------------------|-----------------------------------------------------------------------------|
| No promotion gate between nightly-green and release                     | `promotion-gate.yml` — runs against actual release artifacts, quarantines   |
| No watchdog re-verifying the latest release                             | `watchdog-latest-release.yml` — 6h cadence, un-latests + files issue        |
| No canary channel                                                       | *queued* — needs a second `latest-canary.json` + client channel selector    |
| `patches.py` has no unit tests                                          | `scripts/tests/test_bearbrowser_patches.py` + `packaging-and-update-tests.yml` |
| No unit tests on semver/update-check helpers                            | `scripts/tests/test_update_check.mjs` + same workflow                       |
| No HTTP-level test of the update-check code path                        | *partial* — keyword-level assertion landed; MITM integration test queued    |
| No smoke test on WIF/GCS auth                                           | `rs-mirror-preflight.yml`                                                   |
| No integration test of cockpit boot                                     | *queued*                                                                    |
| No adversarial-review checklist wired into PR template                  | `.github/PULL_REQUEST_TEMPLATE.md`                                          |
| No `CODEOWNERS` forcing review on load-bearing gate files               | `.github/CODEOWNERS`                                                        |
| No watchdog for main-branch red workflows > N hours                     | `main-branch-red-watchdog.yml`                                              |
| Info.plist version substitution silently no-op'd                        | Template uses `__BEARBROWSER_VERSION__` sentinel; substitution asserts round-trip; promotion gate asserts plist version == release tag |
| Silent-skip guards in signing workflows                                 | *queued* — adhoc rehearsal legs                                             |

## Tangential gaps caught by the same design

- **Build-image toolchain drift** (SDK 403, cbindgen codegen regression,
  packager manifest drift, `-j2` OOM — all documented in `nightly-dmg.yml`
  lines 71–142): a weekly *upstream toolchain drift* workflow that runs
  `mach bootstrap` unshimmed on a scratch runner and diffs cbindgen tag +
  Mozilla SDK URL would fail loudly before the nightly loses a day. Queued.
- **`sourceos-source-mirror` freshness:** `parity.yml` checks THIS repo's
  parity but not the mirror it pulls from. Queued.
- **`continue-on-error: true` and `|| true` stanzas** in `nightly-linux.yml`
  (fedora leg, cockpit toolchain, audit non-fatal, AppImage non-fatal): each
  is a red-check-you-learn-to-ignore in the making. The
  `main-branch-red-watchdog` catches the "chronically ignored" pattern by
  proxy but a dedicated "advisory-red budget" would name it.
- **`manifest-validation.yml`** globs every YAML but only parses syntax — no
  schema. Queued.
- **`publish-chocolatey.yml`** shares the `SKIP=1 on missing secret` pattern
  with the two signing workflows. Queued with the signing rehearsal.

## Branding / polish lies that shipped

The user's specific words: "*get the branding and polish and ergonomics and
menus and nice-to-haves integrated.*" Fair — the sovereign
security scaffolding was mostly integrated; the surface treatment was not.

Fixed here:

- **Cockpit tab title** — `<title>SocioProphet Web</title>` from the upstream
  client-vue bundle now rewritten to `<title>BearBrowser Cockpit</title>` by
  `build-cockpit.sh`, with a shipped-value assertion that fails the build if
  the rewrite misses.
- **Start-page Cockpit tile** — pointed at `https://app.socioprophet.ai`
  (remote SaaS!); now points at `resource://bearbrowser-cockpit/index.html`
  (the sovereign local cockpit).
- **New-tab wordmark** — was the emoji `🐻`; now the branded SVG
  (`branding/bearbrowser.svg`) staged next to the page.
- **`Info.plist` version** — hardcoded `150.0.1` across four releases; now a
  `__BEARBROWSER_VERSION__` sentinel that fails loudly if substitution
  misses, checked by the promotion gate against the release tag.
- **Hamburger appMenu** — had zero BearBrowser entries; now has a dedicated
  section with BearNet, BearTrap, BearWall, Cockpit — reachable without
  knowing any `resource://` URL.

Still queued (not shipped this pass):

- **BearTrap surface** — has no page. Fingerprint probes are caught, badged
  on the nav-bar button, but there's no `about:beartrap` view of what was
  seen. Menu items currently anchor at `#beartrap` on the BearNet page.
- **BearWall surface** — same class. Blocked vendors log to console; no
  count, no drawer, no "N blocked this session" chiclet.
- **Preferences pane** — `patches/pref-pane/category-bearbrowser.svg` still
  missing, so the pref-pane block in `patches.py` skips. Stock Firefox prefs
  only.
- **Onboarding flow** — Firefox's is disabled; nothing replaces it. New
  users see a blank start page, no explainer of BearNet / BearTrap /
  sovereign updates.
- **LibreWolf branding sweep** — `browser/branding/bearbrowser` is copied
  from `browser/branding/librewolf` unchanged. `brand.ftl`, About dialog,
  window title still carry upstream text. `verify-linux-packaging.sh`
  catches the packaging-metadata cases; the content strings need a
  dedicated sweep.
- **6 shipped "Firefox" strings** — in `BearCaptureParent.sys.mjs`,
  `registry.json`, and `agent-runtime/README.md`. Trivial edits, queued.

## What this changes about how we ship

- `publish-latest-json.yml` is no longer the sole gate between "release
  cut" and "every user is offered this version". `promotion-gate.yml`
  fires on the same event, downloads the actual release artifacts, and
  quarantines the release (marks it prerelease) on any failure — which
  keeps `latest` pointing at the last known-good.
- `watchdog-latest-release.yml` re-verifies whatever `/latest` resolves to
  every 6 hours. If the currently-shipped release regresses (asset
  corruption, gate got stricter, whatever), it's un-latested
  automatically and an issue is filed.
- `main-branch-red-watchdog.yml` closes the "advisory red check that no
  one noticed" pattern globally, not per-workflow.
- The PR template makes the diff-staring checklist explicit. `CODEOWNERS`
  forces a review request on the specific files that, if silently
  weakened, would regress us to the v150.0.x era.
- Two new unit-test files (`patches.py` + update-check) cover the exact
  bug classes that shipped, and are wired into `packaging-and-update-tests.yml`
  so a PR touching those files runs them.

## What still isn't fixed

Ranked by "would I ship v150.0.6 without this?" — top items are must-have.

1. Cockpit boot integration test (headless nav + waiter resolution)
2. Signing workflow adhoc rehearsal leg
3. BearTrap dedicated surface (about:beartrap)
4. BearWall dedicated surface + on-screen block counter
5. Preferences pane populated + wired into `about:preferences`
6. LibreWolf brand-string sweep (About dialog, brand.ftl, window title)
7. Canary channel + client channel selector
8. HTTP-level MITM test of the update-check code path
9. Onboarding / first-run explainer
10. Upstream toolchain drift watchdog
