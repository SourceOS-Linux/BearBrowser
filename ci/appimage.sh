#!/bin/bash
# Build the BearBrowser AppImage from the real Linux x86_64 binary tarball.
# First successful build: bearbrowser-build-20260630-100322 (140.12.0esr-1).
# Variant: human (default) | tor  via VARIANT env.
set -x
rm -rf AppDir *.AppImage *.zsync
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/packaging/linux/binary-source.env"

VARIANT="${VARIANT:-human}"
case "$VARIANT" in
  human) TARBALL="$BEARBROWSER_HUMAN_TARBALL"; EXPECT_SHA="$BEARBROWSER_HUMAN_SHA256" ;;
  tor)   TARBALL="$BEARBROWSER_TOR_TARBALL";   EXPECT_SHA="$BEARBROWSER_TOR_SHA256" ;;
  *) echo "Unknown variant: $VARIANT (use human|tor)" >&2; exit 2 ;;
esac

mkdir -p AppDir/usr/bin AppDir/usr/lib/bearbrowser AppDir/usr/share/applications
mkdir -p AppDir/usr/share/icons/hicolor/scalable/apps

# ── Acquire and verify the real binary tarball ────────────────────────────────
STAGED="dist/linux/$TARBALL"
if [ ! -f "$STAGED" ]; then
  mkdir -p dist/linux
  echo "Fetching real binary tarball from $BEARBROWSER_GCS_BASE/$TARBALL ..."
  gcloud storage cp "$BEARBROWSER_GCS_BASE/$TARBALL" "$STAGED"
fi
ACTUAL_SHA="$( (sha256sum "$STAGED" 2>/dev/null || shasum -a 256 "$STAGED") | awk '{print $1}')"
[ "$ACTUAL_SHA" = "$EXPECT_SHA" ] || { echo "SHA256 mismatch for $TARBALL: $ACTUAL_SHA != $EXPECT_SHA" >&2; exit 4; }
echo "SHA256 verified: $ACTUAL_SHA"

# Extract the full Gecko runtime (tarball root is bin/).
tar -xzf "$STAGED" -C AppDir/usr/lib/bearbrowser

# Default privacy profile
install -Dm644 profiles/default/user.js AppDir/usr/lib/bearbrowser/defaults/profile/user.js

# Desktop file + icon
install -Dm644 packaging/linux/bearbrowser.desktop AppDir/usr/share/applications/bearbrowser.desktop
install -Dm644 packaging/linux/bearbrowser.desktop AppDir/bearbrowser.desktop
if [ -f branding/bearbrowser.svg ]; then
  install -Dm644 branding/bearbrowser.svg AppDir/usr/share/icons/hicolor/scalable/apps/bearbrowser.svg
  install -Dm644 branding/bearbrowser.svg AppDir/bearbrowser.svg
fi

# AppRun launcher — points at the real launcher inside the extracted runtime.
cat > AppDir/AppRun <<EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
export PATH="\$HERE/usr/bin:\$PATH"
PROFILE_DIR="\${XDG_DATA_HOME:-\$HOME/.local/share}/bearbrowser/profiles/default"
mkdir -p "\$PROFILE_DIR"
exec "\$HERE/usr/lib/bearbrowser/$BEARBROWSER_LAUNCHER_REL" --profile "\$PROFILE_DIR" "\$@"
EOF
chmod 755 AppDir/AppRun

# Fetch appimagetool if needed
[ -x /tmp/appimagetool ] || ( curl -L 'https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage' -o /tmp/appimagetool && chmod +x /tmp/appimagetool )

TAG_NAME=${TAG_NAME:-$BEARBROWSER_UPSTREAM_REF}
OUTPUT=BearBrowser-${VARIANT}-x86_64.AppImage

ARCH=x86_64 VERSION="$TAG_NAME" /tmp/appimagetool AppDir "$OUTPUT"
