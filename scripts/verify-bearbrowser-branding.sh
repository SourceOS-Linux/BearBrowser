#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-}"
if [ -z "$workspace" ]; then
  echo "Usage: verify-bearbrowser-branding WORKSPACE" >&2
  exit 1
fi

if [ ! -d "$workspace" ]; then
  echo "ERROR: workspace does not exist: $workspace" >&2
  exit 1
fi

if [ ! -f "$workspace/.bearbrowser/branding.json" ]; then
  echo "ERROR: missing BearBrowser branding marker: $workspace/.bearbrowser/branding.json" >&2
  exit 1
fi

if ! grep -q '"product": "BearBrowser"' "$workspace/.bearbrowser/branding.json"; then
  echo "ERROR: branding marker does not identify BearBrowser" >&2
  exit 1
fi

# Product-surface scan. We intentionally exclude license, upstream docs, provenance markers, and git metadata.
leftovers="$(find "$workspace" -type f \
  ! -path '*/.git/*' \
  ! -path '*/.bearbrowser/*' \
  ! -path '*/LICENSE*' \
  ! -path '*/COPYING*' \
  ! -path '*/README*' \
  ! -path '*/docs/*' \
  ! -path '*/doc/*' \
  -print0 \
  | xargs -0 grep -IlE 'LibreWolf|librewolf|Libre Wolf' 2>/dev/null \
  | head -n 50 || true)"

if [ -n "$leftovers" ]; then
  echo "ERROR: product-surface LibreWolf branding leftovers detected:" >&2
  echo "$leftovers" >&2
  exit 1
fi

echo "BearBrowser branding verified: $workspace"
