# BearBrowser Homebrew Packaging

BearBrowser must be installable through Homebrew on macOS and Linuxbrew on Linux.

Homebrew packaging is split into two artifacts:

1. **Formula**: installs BearBrowser CLI/runtime/overlay tooling.
2. **Cask**: installs the future signed/notarized macOS GUI app bundle.

## Target install commands

After the SourceOS tap exists:

```bash
brew tap SourceOS-Linux/tap
brew install bearbrowser
```

Equivalent direct syntax:

```bash
brew install SourceOS-Linux/tap/bearbrowser
```

Future GUI app install path:

```bash
brew install --cask SourceOS-Linux/tap/bearbrowser
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

## Current status

The Formula installs useful BearBrowser overlay/runtime tooling before a full browser binary exists. The Cask is a scaffold for the future signed macOS `.app` release artifact.

## Release model

- Formula: CLI tooling, overlay replay, parity checks, metadata, and developer/runtime utilities.
- Cask: GUI browser application.
- Agent runtime OCI image: published separately through GHCR or SourceOS package channels.
