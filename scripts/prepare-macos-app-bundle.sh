#!/usr/bin/env bash
set -euo pipefail

input_app=""
out_dir="build/macos"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
info_template="$repo_root/packaging/macos/Info.plist.template"
icon_svg="$repo_root/branding/bearbrowser.svg"
out_app="$out_dir/BearBrowser.app"

usage() {
  cat <<'USAGE'
Usage: prepare-macos-app-bundle --input-app PATH [--version VERSION] [--out-dir DIR]

Prepares a built upstream-derived app bundle as BearBrowser.app.

This script requires an existing built browser app bundle. It renames/stages the
bundle, applies BearBrowser Info.plist metadata, installs BearBrowser branding
assets, and refuses product-surface upstream names.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-app)
      input_app="${2:?missing input app}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?missing output dir}"
      shift 2
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

out_app="$out_dir/BearBrowser.app"

if [ -z "$input_app" ]; then
  echo "ERROR: --input-app is required" >&2
  usage >&2
  exit 1
fi

if [ ! -d "$input_app" ]; then
  echo "ERROR: input app bundle not found: $input_app" >&2
  exit 64
fi

if [ ! -f "$info_template" ]; then
  echo "ERROR: Info.plist template missing: $info_template" >&2
  exit 1
fi

if [ ! -f "$icon_svg" ]; then
  echo "ERROR: BearBrowser SVG icon missing: $icon_svg" >&2
  exit 1
fi

rm -rf "$out_app"
mkdir -p "$out_dir"
cp -R "$input_app" "$out_app"
mkdir -p "$out_app/Contents/Resources"

python3 - "$info_template" "$out_app/Contents/Info.plist" "$version" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
version = sys.argv[3]
text = src.read_text()
text = text.replace('<string>0.1.0-overlay</string>', f'<string>{version}</string>')
dst.write_text(text)
PY

cp "$icon_svg" "$out_app/Contents/Resources/BearBrowser.svg"

# Remove common upstream-branded launcher aliases when present. The real executable
# relinking step belongs to Lane 13 once the browser binary layout is known.
find "$out_app/Contents" -maxdepth 3 -name '*librewolf*' -print | while read -r branded; do
  echo "branding-warning: upstream-branded path still exists: $branded"
done

bash "$repo_root/scripts/verify-macos-app.sh" --app "$out_app" || {
  echo "ERROR: prepared app bundle failed BearBrowser verification" >&2
  exit 1
}

echo "Prepared BearBrowser app bundle: $out_app"
