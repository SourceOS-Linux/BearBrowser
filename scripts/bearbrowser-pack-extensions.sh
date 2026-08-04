#!/usr/bin/env bash
# MIT License
# Copyright (c) 2026 @mdheller
#
# bearbrowser-pack-extensions.sh — Pack BearBrowser extension directories into
# signed-free .xpi files ready for sideloading into the app bundle.
#
# Each extension directory under extensions/ is zipped from the inside (not
# wrapping the directory itself) and named by its gecko extension ID read from
# manifest.json's browser_specific_settings.gecko.id field.
#
# Usage:
#   ./scripts/bearbrowser-pack-extensions.sh [output_dir]
#
# Arguments:
#   output_dir    Directory to write .xpi files into. Default: build/extensions/
#
# Output:
#   <output_dir>/<gecko-id>.xpi  for each extension in extensions/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
_out_arg="${1:-$REPO/build/extensions}"
# Absolutize the output path before any cd changes the working directory
mkdir -p "$_out_arg"
OUT="$(cd "$_out_arg" && pwd)"

echo "bearbrowser-pack-extensions: packing to $OUT"

packed=0
for ext_dir in "$REPO/extensions"/*/; do
  if [ ! -d "$ext_dir" ]; then
    continue
  fi
  ext_name="$(basename "$ext_dir")"
  manifest="$ext_dir/manifest.json"

  if [ ! -f "$manifest" ]; then
    echo "  WARNING: no manifest.json in $ext_dir — skipping" >&2
    continue
  fi

  # Resolve gecko extension ID from manifest; fall back to <name>@bearbrowser.local
  gecko_id="$(python3 - "$manifest" "$ext_name" <<'PY'
import json, sys
manifest_path, fallback_name = sys.argv[1], sys.argv[2]
try:
    m = json.load(open(manifest_path))
    gecko_id = (
        m.get("browser_specific_settings", {})
         .get("gecko", {})
         .get("id")
        or m.get("applications", {})
         .get("gecko", {})
         .get("id")
    )
    if not gecko_id:
        gecko_id = f"{fallback_name}@bearbrowser.local"
except Exception as e:
    sys.exit(f"ERROR reading {manifest_path}: {e}")
print(gecko_id)
PY
)"

  xpi_path="$OUT/${gecko_id}.xpi"
  # Remove stale xpi so zip doesn't append into an existing archive
  rm -f "$xpi_path"
  (
    cd "$ext_dir"
    zip -r "$xpi_path" . \
      -x "*.DS_Store" \
      -x ".git*" \
      -x "__pycache__/*" \
      -x "*.pyc" \
      -x "*.swp" \
      >/dev/null
  )
  echo "  packed: $ext_name  →  ${gecko_id}.xpi"
  packed=$((packed + 1))
done

if [ "$packed" -eq 0 ]; then
  echo "  WARNING: no extensions found under $REPO/extensions/" >&2
else
  echo "bearbrowser-pack-extensions: $packed extension(s) packed → $OUT"
fi
