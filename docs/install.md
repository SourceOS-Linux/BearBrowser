# Install BearBrowser

BearBrowser is designed to be easy to install, update, and diagnose.

## Immediate Homebrew install path

Until the SourceOS tap repository is promoted, install the Formula directly from this repo:

```bash
brew install --formula https://raw.githubusercontent.com/SourceOS-Linux/BearBrowser/main/packaging/homebrew/Formula/bearbrowser.rb
```

Update the direct Formula install:

```bash
brew update
brew reinstall --formula https://raw.githubusercontent.com/SourceOS-Linux/BearBrowser/main/packaging/homebrew/Formula/bearbrowser.rb
```

## Target Homebrew install path

After `SourceOS-Linux/homebrew-tap` exists and the Formula is promoted:

```bash
brew install SourceOS-Linux/tap/bearbrowser
```

Update:

```bash
brew update
brew upgrade SourceOS-Linux/tap/bearbrowser
```

Verify:

```bash
bearbrowser-doctor
bearbrowser-verify-upstream
```

Use overlay tooling:

```bash
bearbrowser --profile agent-runtime --ref latest --dry-run
```

## Homebrew Cask: future GUI app

Once the signed/notarized macOS app is published:

```bash
brew install --cask SourceOS-Linux/tap/bearbrowser
```

Update:

```bash
brew update
brew upgrade --cask SourceOS-Linux/tap/bearbrowser
```

## Tap requirement

The polished short install commands require this public tap repository:

```text
SourceOS-Linux/homebrew-tap
```

Promotion from this repo into the tap is handled by:

```bash
packaging/homebrew/promote-to-tap.sh
```

## Current install surface

The current Formula installs the BearBrowser operator surface:

- `bearbrowser`
- `bearbrowser-verify-upstream`
- `bearbrowser-doctor`
- `bearbrowser-update`

The full GUI browser binary is the next packaging milestone.
