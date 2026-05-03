#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

required=(
  flake.nix
  settings/profiles/human-secure/policies.json
  settings/profiles/agent-runtime/policies.json
  policy/bearbrowser-contract.yaml
  mounts/agent-browser-mounts.yaml
  manifests/upstream.json
)

for path in "${required[@]}"; do
  if [ ! -e "$path" ]; then
    echo "ERROR: missing required Nix packaging input: $path" >&2
    exit 1
  fi
  echo "ok: $path"
done

if command -v nix >/dev/null 2>&1; then
  echo "ok: nix -> $(command -v nix)"
  nix flake show --allow-import-from-derivation || true
else
  echo "info: nix not installed; structural packaging checks only"
fi

echo "BearBrowser Nix packaging structure verified"
