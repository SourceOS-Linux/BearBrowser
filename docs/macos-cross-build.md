# Sovereign macOS build — cross-compile on our own Linux infra

**Decision (2026-07-18):** BearBrowser's macOS binaries are built by **cross-
compiling on the `epsilon` Forgejo runner** using a `bsys6-macos` image, with all
toolchain inputs served from **our own registry (zot)**. No Apple hardware, no
rented cloud Mac, no GitHub Actions, no Mozilla/Apple CDN at build time.

## Why cross-compile (not a Mac runner, not GitHub)

- **It's the proven path.** Mozilla builds its *own* macOS Firefox by cross-
  compiling on Linux workers — the `macosx64-clang` + `cctools-port` + `macosx-sdk`
  toolchains exist precisely for this. We are doing exactly what upstream does.
- **One sovereign substrate.** We already run `epsilon` + `bsys6` (Linux) +
  Forgejo + zot. Cross-compiling keeps macOS on that same substrate instead of
  introducing a second runner class (Apple silicon) to own and maintain.
- **No external dependency.** The two things I fought for 10 GitHub builds — the
  macOS SDK and the clang toolchain — are *baked into the image from zot*, pinned
  by digest. Nothing is fetched from `swcdn.apple.com` or Mozilla's CI proxy.
- **Reproducible.** The image digest + pinned SDK/clang = byte-reproducible builds.

The GitHub `build-macos.yaml` workflow has been removed. `build-macos-local.sh`,
`provision-macos-sdk.sh`, and `sovereign-unpack-sdk.py` remain — they run on *any*
Mac and are reused to (a) vendor the SDK into zot and (b) build on a Mac runner if
we ever add one.

## Architecture

```
  once, on any licensed Mac          the epsilon runner (Linux), per build
  ─────────────────────────          ────────────────────────────────────
  vendor-macos-sdk-to-zot.sh   ┌───►  bsys6-macos image (from zot)
    package Xcode CLT SDK      │        = bsys6 (clang/rust/node)
    → OCI artifact → zot ──────┘          + cctools-port (ld64, lipo, …)
                                          + macOS SDK  (pulled from zot)
                                          + cross mozconfig
                                     ↓
                              apply-sourceos-overlays.sh --profile human-secure
                                     ↓
                              mach build  (target = aarch64-apple-darwin,
                                           CROSS_COMPILE=1, --with-macos-sdk)
                                     ↓
                              BearBrowser.app  →  zot (OCI artifact) + Forgejo
```

## The three sovereign inputs (all in zot)

1. **macOS SDK** — `scripts/vendor-macos-sdk-to-zot.sh` runs once on a licensed
   Mac: packages the Xcode Command Line Tools SDK (as `scripts/provision-macos-sdk.sh`
   already does) and pushes it to `zot/bearbrowser/toolchains/macos-sdk:<ver>` as an
   OCI artifact, pinned by digest. Apple's SDK license permits using the SDK you're
   licensed for; we host it in our *private* registry, not publicly.
2. **cctools-port** — the Mach-O binutils (ld64, lipo, install_name_tool, …) that a
   Linux host needs to link macOS binaries. Built into the `bsys6-macos` image from
   source (see `ci/bsys6-macos/Dockerfile`), or vendored to zot as a layer.
3. **clang with darwin target** — `bsys6` already carries clang; it just needs the
   Mach-O linker (cctools) + SDK to target darwin. No separate clang fetch.

## Cross mozconfig

`mozconfig/human-secure-macos-cross.mozconfig` sets the cross target, the SDK path
(inside the image), and the cctools linker. It reuses every BearBrowser flag
(naming, telemetry-off, Cocoa toolkit, Widevine, anti-fp via the patch stack).

## The Forgejo workflow

`.forgejo/workflows/macos-cross.yaml` runs on `epsilon` with the `bsys6-macos`
image: `apply-sourceos-overlays.sh --profile human-secure` → cross `mach build` →
locate `BearBrowser.app` → push to zot + Forgejo artifact. Mirrors the shape of
`tor-mode-esr.yaml`.

## Status / what gates execution

- ✅ Decision + scaffold: this doc, the cross mozconfig, `ci/bsys6-macos/Dockerfile`,
  `.forgejo/workflows/macos-cross.yaml`, `scripts/vendor-macos-sdk-to-zot.sh`.
- ⏳ **Needs infra access to run (not yet validated):**
  1. Vendor the SDK to zot (one-time, on a licensed Mac).
  2. Build + push the `bsys6-macos` image to zot (`docker build ci/bsys6-macos`).
  3. Dispatch the Forgejo workflow on `epsilon` and iterate the cross mozconfig /
     cctools flags until `mach build` is green. Cross-compiling Gecko always needs
     a few rounds on the linker/SDK path specifics — that tuning happens here, on
     our infra, not by guessing.

The Dockerfile + mozconfig below are a researched starting point, **not yet a
green build** — they are the substrate to iterate on `epsilon`, replacing the
GitHub trial-and-error with sovereign trial-and-error.
