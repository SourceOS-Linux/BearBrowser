#!/usr/bin/env bash
set -euo pipefail

formula_url="${BEARBROWSER_FORMULA_URL:-https://raw.githubusercontent.com/SourceOS-Linux/BearBrowser/main/packaging/homebrew/Formula/bearbrowser.rb}"
tap_formula="${BEARBROWSER_TAP_FORMULA:-SourceOS-Linux/tap/bearbrowser}"
tap_repo="${BEARBROWSER_TAP_REPO:-SourceOS-Linux/homebrew-tap}"

if ! command -v brew >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: Homebrew is required.

Install Homebrew first:
  https://brew.sh

Then rerun:
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/SourceOS-Linux/BearBrowser/main/install.sh)"
EOF
  exit 1
fi

echo "BearBrowser installer"
echo "Checking SourceOS Homebrew tap..."

if command -v gh >/dev/null 2>&1 && gh repo view "$tap_repo" >/dev/null 2>&1; then
  echo "Installing from tap: $tap_formula"
  brew install "$tap_formula" || brew upgrade "$tap_formula" || brew reinstall "$tap_formula"
else
  echo "SourceOS tap not available locally or not yet created."
  echo "Installing direct Formula from BearBrowser repo: $formula_url"
  brew install --formula "$formula_url" || brew reinstall --formula "$formula_url"
fi

echo
echo "Running diagnostics..."
bearbrowser-doctor || true

echo
echo "BearBrowser installed."
echo "Useful commands:"
echo "  bearbrowser --profile agent-runtime --ref latest --dry-run"
echo "  bearbrowser-verify-upstream"
echo "  bearbrowser-automation-surfaces"
echo "  bearbrowser-update"
