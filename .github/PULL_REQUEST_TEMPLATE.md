<!-- What this changes and why. Focus on the WHY — the diff already says WHAT. -->

## Change

## Why

## Adversarial-review checklist

Every incident that shipped in v150.0.1 → v150.0.5 was caught by *staring at
the diff*, not by CI. Encode that here. Tick each; if not applicable, write N/A.

- [ ] **Sensitive network fetches** — every `fetch(...)` or XHR I added sets
      `credentials:"omit"` and `referrerPolicy:"no-referrer"` unless there is
      an explicit reason to send credentials / referrer. (Bug class: v150.0.5
      update-check Referer leak.)
- [ ] **String parsers** — for any `parseInt`, `Number()`, `parseFloat`, or
      regex I added on user-provided or upstream-provided strings, there is a
      test file with at least one “malformed / edge / suffix” input. (Bug
      class: `Number("4-rc1") === NaN` semver break.)
- [ ] **Packaged-artifact assertions** — if I added a new runtime resource
      (`resource://…`, autoconfig substitution, filter list, sidecar binary,
      cockpit file), `scripts/verify-package.sh` has a new assertion for it,
      OR the existing assertion still fires. (Bug class: BearBlocker shipped
      empty for weeks.)
- [ ] **`FINAL_TARGET_FILES` blocks** — if I added or renamed an actor or
      other packaged file, the list in `scripts/bearbrowser-patches.py` is
      alphabetical and `scripts/tests/test_bearbrowser_patches.py` still
      passes. (Bug class: alpha-sort UnsortedError killing 3 nightlies.)
- [ ] **Auth / IAM changes** — for any new WIF binding, GH secret, GCP role,
      or bucket condition, there is a smoke test (`rs-mirror-preflight.yml`
      or equivalent) that fails fast without waiting for the scheduled
      workflow to fire. (Bug class: 3 wasted mirror runs on WIF audience +
      IAM condition.)
- [ ] **Version metadata** — if this bumps a shipped version, Info.plist
      template still contains `__BEARBROWSER_VERSION__` and the `.deb`/`.rpm`
      metadata reads from the same source of truth. (Bug class: Info.plist
      stuck at 150.0.1 across 4 releases.)
- [ ] **Silent-skip guards** — no `|| true`, no `continue-on-error: true`,
      no `if secret then run else SKIP=1` unless the workflow ALSO fails
      loudly (issue / exit 1) when the silent path is hit for the wrong
      reason. (Bug class: signing pipeline "no-op if secrets absent" with no
      dry-run rehearsal.)
- [ ] **Firefox/Mozilla/LibreWolf strings** — I did not add any user-visible
      string that leaks upstream branding. `verify-linux-packaging.sh` will
      catch obvious ones; the harder ones are inside actors, About pages,
      and shipped module comments.

## Test plan

<!-- Concrete commands run and results. "Green in CI" is not a test plan. -->

## Blast-radius / rollback

<!-- What breaks for existing users if this ships wrong. How do we un-ship? -->
