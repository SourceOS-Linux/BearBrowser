#!/usr/bin/env bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew is required for bearbrowser-update." >&2
  exit 1
fi

formula="${BEARBROWSER_HOMEBREW_FORMULA:-SourceOS-Linux/tap/bearbrowser}"
formula_url="${BEARBROWSER_FORMULA_URL:-https://raw.githubusercontent.com/SourceOS-Linux/BearBrowser/main/packaging/homebrew/Formula/bearbrowser.rb}"
cask="${BEARBROWSER_HOMEBREW_CASK:-SourceOS-Linux/tap/bearbrowser}"

tap_available="false"
if brew tap-info SourceOS-Linux/tap >/dev/null 2>&1; then
  tap_available="true"
fi

brew update

if brew list --formula bearbrowser >/dev/null 2>&1; then
  if [ "$tap_available" = "true" ]; then
    brew upgrade "$formula" || brew reinstall "$formula"
  else
    echo "SourceOS tap not installed yet; refreshing direct Formula install."
    brew reinstall --formula "$formula_url"
  fi
else
  if [ "$tap_available" = "true" ]; then
    echo "BearBrowser Formula is not installed. Installing from tap: $formula"
    brew install "$formula"
  else
    echo "BearBrowser Formula is not installed. Installing direct Formula: $formula_url"
    brew install --formula "$formula_url"
  fi
fi

if brew list --cask bearbrowser >/dev/null 2>&1; then
  if [ "$tap_available" = "true" ]; then
    brew upgrade --cask "$cask" || brew reinstall --cask "$cask"
  else
    echo "BearBrowser Cask is installed, but SourceOS tap is not available. Reinstall after tap promotion."
  fi
else
  echo "BearBrowser Cask is not installed. Future GUI app install: brew install --cask $cask"
fi
