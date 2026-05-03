#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v npm >/dev/null 2>&1; then
  echo "ERROR: npm is required to lock BearBrowser runtime dependencies." >&2
  exit 2
fi

node runtime/verify-runtime-deps.mjs
npm install --package-lock-only
npm audit --omit=dev || {
  echo "npm audit reported findings. Review before release promotion." >&2
  exit 1
}

echo "Runtime dependency lockfile generated or refreshed."
echo "Review package-lock.json, then commit it with the dependency policy update."
