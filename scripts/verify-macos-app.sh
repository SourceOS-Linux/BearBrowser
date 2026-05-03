#!/usr/bin/env bash
set -euo pipefail

app_path="${BEARBROWSER_APP_PATH:-build/macos/BearBrowser.app}"

usage() {
  cat <<'USAGE'
Usage: verify-macos-app [--app PATH]

Verifies BearBrowser.app product identity, signing, and Gatekeeper status.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      app_path="${2:?missing app path}"
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

if [ ! -d "$app_path" ]; then
  echo "ERROR: app bundle not found: $app_path" >&2
  exit 64
fi

plist="$app_path/Contents/Info.plist"
if [ ! -f "$plist" ]; then
  echo "ERROR: Info.plist missing: $plist" >&2
  exit 1
fi

name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist" 2>/dev/null || true)"
display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist" 2>/dev/null || true)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"

if [ "$name" != "BearBrowser" ] && [ "$display_name" != "BearBrowser" ]; then
  echo "ERROR: bundle name/display name must be BearBrowser" >&2
  exit 1
fi

if [ "$bundle_id" != "dev.sourceos.BearBrowser" ]; then
  echo "ERROR: bundle identifier must be dev.sourceos.BearBrowser; found $bundle_id" >&2
  exit 1
fi

if grep -RIlE 'LibreWolf|librewolf|Libre Wolf' "$app_path/Contents" 2>/dev/null | grep -vE '/(_CodeSignature|LICENSE|COPYING|README|legal|licenses)/' | head -1 | grep -q .; then
  echo "ERROR: product-surface upstream branding found inside app bundle" >&2
  grep -RIlE 'LibreWolf|librewolf|Libre Wolf' "$app_path/Contents" 2>/dev/null | grep -vE '/(_CodeSignature|LICENSE|COPYING|README|legal|licenses)/' | head -20 >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

echo "BearBrowser macOS app verified: $app_path"
