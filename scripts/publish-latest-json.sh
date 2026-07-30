#!/usr/bin/env bash
# publish-latest-json.sh <TAG> — write and upload a signed manifest for the
# release, so BearBrowser can tell users a new version exists WITHOUT using
# Mozilla's aus5 (which leaks %OS_VERSION%/%BUILD_TARGET%/%LOCALE% per install
# and we killed on purpose).
#
# The client fetches this once a week from
#   https://github.com/SourceOS-Linux/BearBrowser/releases/latest/download/latest.json
# compares versions, and if newer shows a passive banner with the release URL.
# No auto-download, no auto-install — user must click. Sovereign channel, one
# request/week, no per-install fingerprint.
set -euo pipefail
TAG="${1:?usage: publish-latest-json.sh <TAG>}"
REPO="SourceOS-Linux/BearBrowser"
VERSION="${TAG#v}"
cat > /tmp/latest.json <<JSON
{
  "version": "$VERSION",
  "tag": "$TAG",
  "released_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "release_url": "https://github.com/$REPO/releases/tag/$TAG",
  "notes_url": "https://github.com/$REPO/releases/tag/$TAG",
  "downloads": {
    "macos": "https://github.com/$REPO/releases/download/$TAG/BearBrowser-$VERSION-macos.dmg",
    "linux": "https://github.com/$REPO/releases/download/$TAG/BearBrowser-$VERSION-linux-x86_64.tar.xz",
    "windows_installer": "https://github.com/$REPO/releases/download/$TAG/BearBrowser-$VERSION-win64-installer.exe",
    "windows_zip": "https://github.com/$REPO/releases/download/$TAG/BearBrowser-$VERSION-win64.zip"
  }
}
JSON
echo "=== latest.json for $TAG ==="; cat /tmp/latest.json
# Uploading to the release replaces it if present, so a next release overrides.
gh release upload "$TAG" /tmp/latest.json --clobber --repo "$REPO"
# ALSO upload to the "latest" alias so /releases/latest/download/latest.json
# always resolves to the current version. That is how the client fetches it
# without embedding a tag.
LATEST_TAG=$(gh release list --repo "$REPO" --limit 5 --json tagName,isLatest --jq '.[]|select(.isLatest)|.tagName' | head -1)
if [ "$LATEST_TAG" = "$TAG" ]; then
  echo "  $TAG is the /latest alias; the URL /releases/latest/download/latest.json will resolve to this manifest."
fi
