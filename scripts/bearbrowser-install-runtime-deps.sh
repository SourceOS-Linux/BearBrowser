#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is required to install BearBrowser automation runtime dependencies." >&2
  echo "Install Node/npm, or use the BearBrowser Brewfile." >&2
  exit 2
fi

if [ ! -f "$repo_root/package.json" ]; then
  echo "ERROR: package.json not found at $repo_root/package.json" >&2
  exit 1
fi

cd "$repo_root"
echo "Installing BearBrowser automation runtime dependencies in: $repo_root"
npm install --omit=dev

echo
echo "BearBrowser runtime dependencies installed."
echo "Try:"
echo "  bearbrowser-playwright --dry-run"
echo "  bearbrowser-stagehand --dry-run"
