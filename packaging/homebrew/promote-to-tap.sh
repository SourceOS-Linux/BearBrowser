#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
tap_repo="${BEARBROWSER_HOMEBREW_TAP_REPO:-SourceOS-Linux/homebrew-tap}"
tap_dir="${BEARBROWSER_HOMEBREW_TAP_DIR:-$HOME/dev/homebrew-tap}"

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI is required to create or clone the tap repo" >&2
  exit 1
fi

if ! gh repo view "$tap_repo" >/dev/null 2>&1; then
  echo "ERROR: tap repo does not exist: $tap_repo" >&2
  echo "Create it first: gh repo create $tap_repo --public --description 'Homebrew tap for SourceOS packages' --clone=false" >&2
  exit 1
fi

mkdir -p "$(dirname "$tap_dir")"
if [ ! -d "$tap_dir/.git" ]; then
  git clone "git@github.com:${tap_repo}.git" "$tap_dir"
fi

mkdir -p "$tap_dir/Formula" "$tap_dir/Casks"
cp "$repo_root/packaging/homebrew/Formula/bearbrowser.rb" "$tap_dir/Formula/bearbrowser.rb"
cp "$repo_root/packaging/homebrew/Casks/bearbrowser.rb" "$tap_dir/Casks/bearbrowser.rb"

cd "$tap_dir"
git status --short
git add Formula/bearbrowser.rb Casks/bearbrowser.rb

if git diff --cached --quiet; then
  echo "No tap changes to commit."
else
  git commit -m "Add BearBrowser Homebrew Formula and Cask"
  git push origin main
fi

echo "Tap promotion complete."
echo "Install Formula: brew install SourceOS-Linux/tap/bearbrowser"
echo "Install Cask:    brew install --cask SourceOS-Linux/tap/bearbrowser"
