#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew is required for bearbrowser-update." >&2
  exit 1
fi

formula="${BEARBROWSER_HOMEBREW_FORMULA:-SourceOS-Linux/tap/bearbrowser}"
cask="${BEARBROWSER_HOMEBREW_CASK:-SourceOS-Linux/tap/bearbrowser}"

brew update

if brew list --formula bearbrowser >/dev/null 2>&1; then
  brew upgrade "$formula" || brew reinstall "$formula"
else
  echo "BearBrowser Formula is not installed. Install it with: brew install $formula"
fi

if brew list --cask bearbrowser >/dev/null 2>&1; then
  brew upgrade --cask "$cask" || brew reinstall --cask "$cask"
else
  echo "BearBrowser Cask is not installed. Future GUI app install: brew install --cask $cask"
fi
