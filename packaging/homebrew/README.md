# BearBrowser Homebrew Packaging

BearBrowser must be installable and updateable through Homebrew on macOS and Linuxbrew on Linux.

Homebrew packaging is split into two artifacts:

1. **Formula**: installs BearBrowser CLI/runtime/overlay tooling.
2. **Cask**: installs the signed/notarized macOS GUI app bundle when available.

## User install path

Once the SourceOS tap exists, the preferred user-facing install is:

```bash
brew install SourceOS-Linux/tap/bearbrowser
```

The equivalent explicit tap flow is:

```bash
brew tap SourceOS-Linux/tap
brew install bearbrowser
```

Future GUI app install path:

```bash
brew install --cask SourceOS-Linux/tap/bearbrowser
```

## User update path

```bash
brew update
brew upgrade SourceOS-Linux/tap/bearbrowser
```

BearBrowser also installs an update helper:

```bash
bearbrowser-update
```

Diagnostic command:

```bash
bearbrowser-doctor
```

## Required tap repository

Create this GitHub repo:

```text
SourceOS-Linux/homebrew-tap
```

Homebrew maps `SourceOS-Linux/tap` to the GitHub repository `SourceOS-Linux/homebrew-tap`.

## Files to promote into the tap

```text
packaging/homebrew/Formula/bearbrowser.rb -> Formula/bearbrowser.rb
packaging/homebrew/Casks/bearbrowser.rb  -> Casks/bearbrowser.rb
```

Promotion command after `SourceOS-Linux/homebrew-tap` exists:

```bash
packaging/homebrew/promote-to-tap.sh
```

## Current status

The Formula installs useful BearBrowser overlay/runtime tooling before a full browser binary exists:

- `bearbrowser`
- `bearbrowser-verify-upstream`
- `bearbrowser-doctor`
- `bearbrowser-update`

The Cask is a scaffold for the future signed macOS `.app` release artifact.

## Release model

- Formula: CLI tooling, overlay replay, parity checks, metadata, developer/runtime utilities, and install/update helpers.
- Cask: GUI browser application.
- Agent runtime OCI image: published separately through GHCR or SourceOS package channels.

## Product rule

Homebrew is a first-class distribution surface. Every release should answer three user questions clearly:

1. How do I install it?
2. How do I update it?
3. How do I verify it is healthy?
