# Anti-fingerprint: building + measuring on the Forgejo pipeline

How the anti-fingerprint Gecko patches get compiled and measured by the project's
existing Firefox build CI (Forgejo/Woodpecker), respecting the read-only mirror.

## Constraint
The build repo is `SourceOS-Linux/librewolf-source-mirror`, which AGENTS.md marks
**read-only** (no direct commits except via the approved sync). So our patches are
**not** committed there. They live in this overlay at
`gecko-patches/anti-fingerprint/` and are injected into a transient workspace clone
at build time.

## How injection works (already wired)
`scripts/apply-sourceos-overlays.sh` clones the mirror into
`build/workspaces/<profile>-<ref>/source`, then:
- copies `gecko-patches/anti-fingerprint/*.patch` → `<workspace>/source/patches/`
- appends them to `<workspace>/source/assets/patches.txt` (canvas, then audio)

`bearbrowser-patches.py` (run by `make`) then applies them with `patch -p1` to the
extracted Firefox source. **Verified** with `check-patchfail.sh`: the full upstream
sequence + both patches apply to a fresh Firefox 150.0.1 with zero rejects.

## Build + measure (the Forgejo job)
The pipeline step is the standard overlay build, then the geckodriver measurement:

```sh
# 1. Materialize the patched workspace (injects our patches)
scripts/apply-sourceos-overlays.sh --profile human-secure --ref latest

# 2. Build (the heavy step — needs the bootstrapped toolchain on the runner)
ws="$(find build/workspaces -maxdepth 2 -type d -name source | tail -1)"
( cd "$ws" && make bootstrap && make build )

# 3. Measure the REAL binary (authoritative — sees what Playwright masks)
bin="$(find "$ws" -type f \( -name firefox -o -name bearbrowser \) -path '*dist*' \
        | grep -vE '\.dSYM' | head -1)"
npm ci   # geckodriver + selenium-webdriver are devDependencies
export PATH="$PWD/node_modules/.bin:$PATH"
node scripts/measure-fingerprint.mjs --profile human-secure --bin "$bin"
```

Step 3 is the same engine-agnostic measurement used in the GitHub Tier-3 job
(`.github/workflows/anti-fingerprint.yml`). It reports the real-binary scorecard
and — critically — authoritatively answers the open questions Playwright can't:
the **timezone** spoof (Playwright sets `TZ` and masks it) and real **letterboxing**.

## What "green" means here
After the build, the measurement should show, on the real binary:
- `canvas text metric` → `int` (W4 canvas patch compiled in)
- `audio (oac)` → randomized across two sessions (W6 patch compiled in)
- `non-base fonts` → `0/14` (bundled fonts + `font.system.whitelist` active)
- `rfp_timezone` → offset 0 / neutral — **if not, that's the one real gap to fix**
  (add a `TZ=UTC` launcher env + confirm RFP timezone).

Lock any newly-confirmed behaviours into `verify-gecko-rfp.mjs` once measured.

## Trigger
The mirror's own Forgejo workflow builds the mirror's patch set; to build *with*
our overlay patches, the job must run `apply-sourceos-overlays.sh` first (above).
Wire that as a Forgejo workflow in the overlay/CI of your choice, or run the GitHub
Tier-3 job (`workflow_dispatch`) against a large/self-hosted runner — both paths
produce the same patched binary + scorecard.
