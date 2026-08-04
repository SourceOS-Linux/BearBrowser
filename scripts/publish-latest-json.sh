#!/usr/bin/env bash
# publish-latest-json.sh <TAG> [--channel stable|canary] — write and upload a
# signed manifest for the release, so BearBrowser can tell users a new version
# exists WITHOUT using Mozilla's aus5 (which leaks %OS_VERSION%/%BUILD_TARGET%/
# %LOCALE% per install and we killed on purpose).
#
# Two channels, same shape:
#   stable → latest.json         (default; clients on channel="stable" fetch)
#   canary → latest-canary.json  (opt-in soak; clients on channel="canary" fetch)
#
# Canary path: a release tagged like v150.0.7-rc1 publishes as canary and gets
# 24-72h of soak before we optionally re-tag it as stable. That contains
# regressions like the v150.0.5 Referer leak or the semver rc-suffix parse
# break to the population that explicitly opted in.
#
# The client fetches once a week from either
#   https://github.com/SourceOS-Linux/BearBrowser/releases/latest/download/latest.json
#   https://github.com/SourceOS-Linux/BearBrowser/releases/latest/download/latest-canary.json
# depending on `bearbrowser.update.channel`. Compares versions, and if newer
# shows a passive banner with the release URL. No auto-download, no auto-
# install — user must click. Sovereign channel, one request/week, no per-
# install fingerprint.
set -euo pipefail
TAG="${1:?usage: publish-latest-json.sh <TAG> [--channel stable|canary]}"
CHANNEL="stable"
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --channel) CHANNEL="${2:?}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
case "$CHANNEL" in
  stable) MANIFEST="latest.json" ;;
  canary) MANIFEST="latest-canary.json" ;;
  *) echo "invalid channel: $CHANNEL (want stable|canary)" >&2; exit 2 ;;
esac

REPO="SourceOS-Linux/BearBrowser"
VERSION="${TAG#v}"
OUT="/tmp/$MANIFEST"
cat > "$OUT" <<JSON
{
  "channel": "$CHANNEL",
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
echo "=== $MANIFEST for $TAG (channel=$CHANNEL) ==="; cat "$OUT"
# Uploading to the release replaces it if present, so a next release overrides.
gh release upload "$TAG" "$OUT" --clobber --repo "$REPO"
# ALSO uploaded to the "latest" alias via GitHub's /releases/latest resolver:
# once this release is marked --latest, the URL
#   /releases/latest/download/<MANIFEST>
# resolves to this manifest. Canary uses the SAME resolver but a different
# filename, so a stable release still has /latest/download/latest.json AND a
# canary manifest coexisting.
LATEST_TAG=$(gh release list --repo "$REPO" --limit 5 --json tagName,isLatest --jq '.[]|select(.isLatest)|.tagName' | head -1)
if [ "$LATEST_TAG" = "$TAG" ]; then
  echo "  $TAG is the /latest alias; /releases/latest/download/$MANIFEST resolves to this manifest."
fi
