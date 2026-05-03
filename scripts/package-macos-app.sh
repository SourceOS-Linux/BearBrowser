#!/usr/bin/env bash
set -euo pipefail

version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
app_path="${BEARBROWSER_APP_PATH:-build/macos/BearBrowser.app}"
out_dir="${BEARBROWSER_DIST_DIR:-dist/macos}"
dmg_path="$out_dir/BearBrowser-${version}-macos-universal.dmg"

usage() {
  cat <<'USAGE'
Usage: package-macos-app [--app PATH] [--version VERSION] [--out-dir DIR]

Packages a signed/notarized BearBrowser.app into a DMG.

This script requires a real BearBrowser.app. It does not synthesize a fake app.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      app_path="${2:?missing app path}"
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

dmg_path="$out_dir/BearBrowser-${version}-macos-universal.dmg"

if [ ! -d "$app_path" ]; then
  echo "ERROR: BearBrowser app bundle not found: $app_path" >&2
  echo "Lane 13 must produce a real BearBrowser.app before packaging." >&2
  exit 64
fi

if [ "$(basename "$app_path")" != "BearBrowser.app" ]; then
  echo "ERROR: app bundle must be named BearBrowser.app" >&2
  exit 1
fi

mkdir -p "$out_dir"
rm -f "$dmg_path"

hdiutil create \
  -volname "BearBrowser" \
  -srcfolder "$app_path" \
  -ov \
  -format UDZO \
  "$dmg_path"

sha256="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"

echo "DMG: $dmg_path"
echo "SHA256: $sha256"
