#!/usr/bin/env bash
# Build BearBrowser .deb package
# Usage: ./build-deb.sh [version] [arch]
# Requires: dpkg-deb, BearBrowser.app or Linux binary in dist/

set -euo pipefail

VERSION="${1:-0.1.0}"
ARCH="${2:-amd64}"
PACKAGE="bearbrowser"
STAGE_DIR="$(mktemp -d)"
DEB_ROOT="$STAGE_DIR/DEBIAN"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist/linux"

echo "Building $PACKAGE ${VERSION} (${ARCH})..."

# Create package structure
mkdir -p "$DEB_ROOT"
mkdir -p "$STAGE_DIR/usr/bin"
mkdir -p "$STAGE_DIR/usr/share/applications"
mkdir -p "$STAGE_DIR/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$STAGE_DIR/usr/share/metainfo"
mkdir -p "$STAGE_DIR/usr/lib/bearbrowser"

# Install binary
if [ -f "$DIST_DIR/BearBrowser" ]; then
  cp "$DIST_DIR/BearBrowser" "$STAGE_DIR/usr/lib/bearbrowser/"
  chmod 0755 "$STAGE_DIR/usr/lib/bearbrowser/BearBrowser"
  cat > "$STAGE_DIR/usr/bin/bearbrowser" << 'EOF'
#!/bin/sh
exec /usr/lib/bearbrowser/BearBrowser --profile ~/.bearbrowser/profiles/default "$@"
EOF
  chmod 0755 "$STAGE_DIR/usr/bin/bearbrowser"
else
  echo "WARNING: No Linux binary at $DIST_DIR/BearBrowser — stub install only"
  cat > "$STAGE_DIR/usr/bin/bearbrowser" << 'EOF'
#!/bin/sh
echo "BearBrowser binary not installed. Awaiting GCP build pipeline."
echo "Track: https://github.com/SourceOS-Linux/BearBrowser/releases"
exit 1
EOF
  chmod 0755 "$STAGE_DIR/usr/bin/bearbrowser"
fi

# Desktop file + metainfo
cp "$REPO_ROOT/packaging/linux/bearbrowser.desktop" "$STAGE_DIR/usr/share/applications/"

# Icon placeholder
if [ -f "$REPO_ROOT/branding/bearbrowser.svg" ]; then
  cp "$REPO_ROOT/branding/bearbrowser.svg" "$STAGE_DIR/usr/share/icons/hicolor/scalable/apps/"
fi

# DEBIAN metadata
sed "s/^Version:.*/Version: $VERSION/; s/^Architecture:.*/Architecture: $ARCH/" \
  "$SCRIPT_DIR/control" > "$DEB_ROOT/control"
cp "$SCRIPT_DIR/postinst" "$DEB_ROOT/postinst"
cp "$SCRIPT_DIR/prerm"    "$DEB_ROOT/prerm"
chmod 755 "$DEB_ROOT/postinst" "$DEB_ROOT/prerm"

OUTPUT="${PACKAGE}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$OUTPUT"
echo "Built: $OUTPUT"
