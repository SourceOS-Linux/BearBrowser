#!/usr/bin/env bash
set -euo pipefail

app_path="${BEARBROWSER_APP_PATH:-build/macos/BearBrowser.app}"
identity="${BEARBROWSER_CODESIGN_IDENTITY:-}"
notary_profile="${BEARBROWSER_NOTARYTOOL_PROFILE:-}"

usage() {
  cat <<'USAGE'
Usage: sign-notarize-macos-app [--app PATH]

Signs and notarizes BearBrowser.app.

Required environment:
  BEARBROWSER_CODESIGN_IDENTITY
  BEARBROWSER_NOTARYTOOL_PROFILE
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

if [ -z "$identity" ]; then
  echo "ERROR: BEARBROWSER_CODESIGN_IDENTITY is required" >&2
  exit 64
fi

if [ -z "$notary_profile" ]; then
  echo "ERROR: BEARBROWSER_NOTARYTOOL_PROFILE is required" >&2
  exit 64
fi

codesign --force --deep --options runtime --timestamp --sign "$identity" "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"

zip_path="$(dirname "$app_path")/BearBrowser-notary.zip"
rm -f "$zip_path"
ditto -c -k --keepParent "$app_path" "$zip_path"

xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"

echo "BearBrowser app signed and notarized: $app_path"
