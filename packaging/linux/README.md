# BearBrowser Linux Distribution

BearBrowser is a first-class Linux browser. Linux is not a fallback surface.

## Product identity

- App name: `BearBrowser`
- App ID: `dev.sourceos.BearBrowser`
- Desktop entry: `dev.sourceos.BearBrowser.desktop`
- AppStream metadata: `dev.sourceos.BearBrowser.metainfo.xml`
- Icon name: `dev.sourceos.BearBrowser`
- Profile name: `BearBrowser`

## Release artifact families

Human secure browser:

- Nix package
- Flatpak
- AppImage
- `.deb`
- `.rpm`
- tarball

Agent browser runtime:

- Nix package
- OCI image
- tarball/runtime closure
- optional systemd user service template

## Linux desktop integration

BearBrowser packages should install:

- desktop entry
- AppStream metadata
- icon theme assets
- MIME handlers for HTTP/HTTPS and common web documents
- profile policy metadata
- release metadata

## Linux sandbox and policy posture

BearBrowser should integrate with Linux security primitives where appropriate:

- XDG portals for user-mediated desktop access
- namespaces for agent-runtime containment
- seccomp where supported
- AppArmor/SELinux profiles where distribution packaging supports them
- PolicyFabric for governed network, filesystem, capture, credential, extension, native messaging, clipboard, and media decisions

## Promotion gates

A Linux package cannot be promoted unless:

1. Product-facing metadata says BearBrowser.
2. Desktop entry validates structurally.
3. AppStream metadata validates structurally.
4. Icon assets are present.
5. Upstream product branding is absent from product surfaces.
6. Human-secure and agent-runtime profile outputs remain separate.
7. Release metadata includes upstream ref, BearBrowser revision, profile, target system, and policy contract hash.

## Current status

This lane adds Linux desktop identity and package metadata scaffolding. The full browser binary still depends on Lane 13.
