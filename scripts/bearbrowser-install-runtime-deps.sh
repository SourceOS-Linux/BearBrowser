#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
include_stagehand="false"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-install-runtime-deps [--include-stagehand]

Installs BearBrowser default automation runtime dependencies.

Stagehand is optional and excluded by default until its transitive audit findings are resolved.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --include-stagehand)
      include_stagehand="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

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
echo "Installing BearBrowser default automation runtime dependencies in: $repo_root"
npm install --omit=dev

if [ "$include_stagehand" = "true" ]; then
  echo
  echo "WARNING: installing optional Stagehand peer dependency."
  echo "Stagehand currently has transitive audit findings in the npm tree; do not promote this path to release until Lane 12 is cleared."
  npm install --no-save @browserbasehq/stagehand@3.3.0
fi

echo
echo "BearBrowser runtime dependencies installed."
echo "Try:"
echo "  bearbrowser-playwright --dry-run"
echo "  bearbrowser-stagehand --dry-run"
