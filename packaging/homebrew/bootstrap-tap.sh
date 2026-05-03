#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
tap_repo="${BEARBROWSER_HOMEBREW_TAP_REPO:-SourceOS-Linux/homebrew-tap}"
tap_dir="${BEARBROWSER_HOMEBREW_TAP_DIR:-$HOME/dev/homebrew-tap}"

desc="Homebrew tap for SourceOS packages, including BearBrowser."

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: Homebrew is required." >&2
  exit 1
fi

if ! gh repo view "$tap_repo" >/dev/null 2>&1; then
  gh repo create "$tap_repo" --public --description "$desc" --clone=false
  echo "Created tap repo: $tap_repo"
else
  echo "Tap repo already exists: $tap_repo"
fi

bash "$repo_root/packaging/homebrew/promote-to-tap.sh"

echo
echo "Validating tap metadata..."
brew tap SourceOS-Linux/tap || true
brew info SourceOS-Linux/tap/bearbrowser || true

echo
echo "Tap bootstrap complete."
echo "Install Formula: brew install SourceOS-Linux/tap/bearbrowser"
echo "Update Formula:  brew update && brew upgrade SourceOS-Linux/tap/bearbrowser"
echo "Future Cask:     brew install --cask SourceOS-Linux/tap/bearbrowser"
