# BearBrowser macOS Distribution

BearBrowser must ship as a first-class macOS application, not as an upstream-branded browser artifact.

## Required artifacts

- `BearBrowser.app`
- `BearBrowser-${version}-macos-universal.dmg`
- release metadata JSON
- SHA256 for the DMG
- notarization log/status

## Required app identity

- App name: `BearBrowser`
- Bundle display name: `BearBrowser`
- Bundle identifier: `dev.sourceos.BearBrowser`
- Icon: BearBrowser icon
- Profile name: BearBrowser
- Product-facing upstream names: disallowed

## Signing and notarization gates

A Cask release cannot be promoted unless:

1. `codesign --verify --deep --strict BearBrowser.app` passes.
2. `spctl --assess --type execute BearBrowser.app` passes.
3. Apple notarization succeeds.
4. The DMG is created from the signed/notarized app.
5. The DMG SHA256 is computed and committed to the Cask.
6. The app opens without Gatekeeper failure.
7. Product-surface branding scan passes.

## Required environment

The release host must provide Apple Developer signing credentials:

- `BEARBROWSER_CODESIGN_IDENTITY`
- `BEARBROWSER_NOTARYTOOL_PROFILE` or equivalent notarytool credentials

## Scripts

- `scripts/package-macos-app.sh`
- `scripts/sign-notarize-macos-app.sh`
- `scripts/verify-macos-app.sh`
- `scripts/update-homebrew-cask.sh`

## Current status

This lane defines the release path and gates. It does not yet produce a real browser binary. The real `BearBrowser.app` depends on Lane 13 full browser binary build completion.
