#!/usr/bin/env bash
set -euo pipefail

app_path="${BEARBROWSER_APP_PATH:-build/macos/BearBrowser.app}"
skip_signing="false"

usage() {
  cat <<'USAGE'
Usage: verify-macos-app [--app PATH] [--skip-signing]

Verifies BearBrowser.app product identity, signing, and Gatekeeper status.

Options:
  --app           Path to the app bundle. Default: build/macos/BearBrowser.app.
  --skip-signing  Skip codesign verification and spctl Gatekeeper assessment.
                  Use for binary overlay builds (ad-hoc signatures only) and CI
                  environments without a valid Developer ID certificate.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      app_path="${2:?missing app path}"
      shift 2
      ;;
    --skip-signing)
      skip_signing="true"
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
  echo "ERROR: bundle name/display name must be BearBrowser; found name='$name' display_name='$display_name'" >&2
  exit 1
fi

if [ "$bundle_id" != "dev.sourceos.BearBrowser" ]; then
  echo "ERROR: bundle identifier must be dev.sourceos.BearBrowser; found $bundle_id" >&2
  exit 1
fi

# Verify the BearBrowser launcher wrapper exists as the declared CFBundleExecutable.
bundle_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
if [ "$bundle_executable" != "BearBrowser" ]; then
  echo "ERROR: CFBundleExecutable must be 'BearBrowser'; found '$bundle_executable'" >&2
  exit 1
fi
launcher="$app_path/Contents/MacOS/BearBrowser"
if [ ! -f "$launcher" ] || [ ! -x "$launcher" ]; then
  echo "ERROR: BearBrowser launcher not found or not executable: $launcher" >&2
  exit 1
fi

# Check for upstream branding in text-format product-surface files.
# grep -I skips binary files, so compiled engine code is intentionally excluded —
# only metadata, desktop files, plist files, and scripts are checked.
# Exclusions:
#   - Code signature directories (_CodeSignature)
#   - License/attribution files (required to preserve upstream provenance)
#   - BearBrowser-injected profile files (user.js, bearbrowser-user.js) — these
#     may reference "LibreWolf" in comments describing what the upstream does
#   - The BearBrowser launcher wrapper itself
branding_hits="$(grep -RIlE 'LibreWolf|librewolf|Libre Wolf' "$app_path/Contents" 2>/dev/null \
  | grep -vE '/(_CodeSignature|LICENSE|COPYING|README|legal|licenses|legal-notices|license-notices|attribution)/' \
  | grep -vE '/(bearbrowser-user\.js|user\.js|bearbrowser-metadata/)' \
  | grep -v '/Contents/MacOS/BearBrowser$' \
  || true)"

if [ -n "$branding_hits" ]; then
  echo "ERROR: upstream branding found in text-format product-surface files:" >&2
  echo "$branding_hits" | head -20 >&2
  exit 1
fi

if [ "$skip_signing" = "true" ]; then
  echo "note: skipping code signature and Gatekeeper verification (--skip-signing)"
else
  codesign --verify --deep --strict --verbose=2 "$app_path"
  spctl --assess --type execute --verbose=4 "$app_path"
fi

echo "BearBrowser macOS app verified: $app_path"
