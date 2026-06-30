# BearBrowser Release Artifacts

BearBrowser releases should publish separate human and agent artifacts. The two variants share the same LibreWolf-derived upstream base when possible, but they must not share runtime profile state, credential state, or policy defaults.

## Artifact families

### Human Secure Browser

Profile: `human-secure`

Expected artifacts:

- Nix package: `bearbrowser-human-secure`
- Desktop package: `BearBrowser-human-secure-${upstreamRef}-${sourceosRevision}-${system}`
- Source overlay manifest: `bearbrowser-human-secure-overlay-manifest.json`

### Agent Browser Runtime

Profile: `agent-runtime`

Expected artifacts:

- Nix package: `bearbrowser-agent-runtime`
- OCI image: `ghcr.io/sourceos-linux/bearbrowser-agent-runtime:${version}`
- Runtime package: `BearBrowser-agent-runtime-${upstreamRef}-${sourceosRevision}-${system}`
- Source overlay manifest: `bearbrowser-agent-runtime-overlay-manifest.json`

## Required metadata

Every release artifact should include:

- BearBrowser version
- LibreWolf upstream ref
- SourceOS/BearBrowser git revision
- Patch-stack hash
- Profile name
- Target system
- Build timestamp
- Policy contract version
- Mount plan version when agent-runtime

## Promotion gates

A BearBrowser release cannot be promoted unless:

1. Mirror parity passes.
2. Overlay dry runs pass for both profiles.
3. Full overlay application passes for the released profile.
4. Patch replay is deterministic.
5. Generated workspace is not committed.
6. Agent-runtime artifacts include policy, mount, and provenance contracts.
7. Human and agent profile state remain isolated.

## Build status

As of 2026-06-30, the first successful binary build
(`bearbrowser-build-20260630-100322`, `140.12.0esr-1`) produced two real Linux
x86_64 runtimes (human-secure + tor-mode). The Linux packaging
(deb/snap/appimage/flatpak) now consumes these real binaries — see
`packaging/RELEASE.md` for SHA256s and the GCS source path, and
`packaging/linux/binary-source.env` for the single source of truth. Windows and
macOS binaries are still pending their builds; their package manifests
(choco/winget/homebrew) intentionally keep placeholder checksums.
