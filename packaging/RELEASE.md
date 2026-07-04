# BearBrowser Release Notes

## 0.1.0 — `140.12.0esr-1` (Linux x86_64, first shippable binary)

**Date:** 2026-06-30
**Build:** `bearbrowser-build-20260630-100322` (Mozilla BearBrowser `140.12.0esr-1`)

This is the **first successful BearBrowser binary build** — the prior 10 GCP
build attempts failed. Two real Linux x86_64 runtimes now exist and are wired
into packaging, so BearBrowser is installable on Linux for the first time. This
closes the "pre-binary while competitors ship daily" maturity risk that the
competitive research flagged as the #1 gating issue.

### Shippable now — Linux x86_64

Both tarballs extract to a top-level `bin/` directory containing the full Gecko
runtime; the launcher executable is `bin/bearbrowser`.

| Variant       | Tarball                                          | Size  | SHA256 |
|---------------|--------------------------------------------------|-------|--------|
| human-secure  | `bearbrowser-human-secure-linux-x86_64.tar.gz`   | 768MB | `a94bda8c5e51122f578b53b1df01ddd9de7af12dc0ab40815eb4c4b1347bc7fb` |
| tor-mode      | `bearbrowser-tor-mode-linux-x86_64.tar.gz`       | 694MB | `0f29fc07448f5cb549d919458dedeefc50cd147063515cd7e77862ed8a1c56ad` |

**Source of truth (GCS):**
`gs://sourceos-artifacts-socioprophet/bearbrowser-builds/bearbrowser-build-20260630-100322/artifacts/`

These SHA256s are recorded once in `packaging/linux/binary-source.env` and
consumed by every Linux packaging recipe, which verifies the hash before
extracting.

### Packaging wired to the real binary

The following recipes now fetch the real tarball from GCS (or a staged copy),
verify the SHA256, extract the Gecko runtime, and launch `bin/bearbrowser` — no
more "binary not present / GCP build pending" stub or Firefox-ESR fallback:

- `packaging/linux/deb/build-deb.sh` — extracts into `/usr/lib/bearbrowser`,
  `/usr/bin/bearbrowser` shim; `--variant human|tor`.
- `packaging/linux/snap/snapcraft.yaml` — `version: 140.12.0esr-1`; variant via
  `BEARBROWSER_SNAP_VARIANT`.
- `ci/appimage.sh` — `BearBrowser-${VARIANT}-x86_64.AppImage`; variant via
  `VARIANT` env.
- `packaging/linux/flatpak/dev.sourceos.BearBrowser.yaml` and
  `ai.sourceos.BearBrowser.json` — `type: archive` source with the recorded
  SHA256 (mirrored to `downloads.sourceos.dev`).

### Still pending (binaries do not exist yet)

- **Windows** (`BearBrowser-win64.zip`) — choco/winget manifests still carry
  `SKIP`/placeholder checksums on purpose.
- **macOS** (`BearBrowser-#{version}-macos-universal.dmg`) — homebrew cask still
  `sha256 :no_check` on purpose.
- **RPM** binary payload — `packaging/linux/rpm/bearbrowser.spec` still installs
  desktop/metadata only; tarball wiring tracked for the next pass.

These placeholders are intentionally left as-is until the corresponding builds
land.
