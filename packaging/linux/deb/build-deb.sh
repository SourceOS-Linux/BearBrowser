#!/usr/bin/env bash
# Build BearBrowser .deb package from the real Linux x86_64 binary tarball.
# Usage: ./build-deb.sh [version] [arch] [variant]
#   variant: human | tor   (default: human)
# Requires: dpkg-deb. The real binary tarball is fetched from GCS (gcloud auth)
# or picked up if already staged in dist/linux/.
#
# First successful build: bearbrowser-build-20260630-100322 (140.12.0esr-1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/packaging/linux/binary-source.env"

VERSION="${1:-$BEARBROWSER_VERSION}"
ARCH="${2:-amd64}"
VARIANT="${3:-human}"
PACKAGE="bearbrowser"
STAGE_DIR="$(mktemp -d)"
DEB_ROOT="$STAGE_DIR/DEBIAN"
DIST_DIR="$REPO_ROOT/dist/linux"

case "$VARIANT" in
  human) TARBALL="$BEARBROWSER_HUMAN_TARBALL"; EXPECT_SHA="$BEARBROWSER_HUMAN_SHA256" ;;
  tor)   TARBALL="$BEARBROWSER_TOR_TARBALL";   EXPECT_SHA="$BEARBROWSER_TOR_SHA256" ;;
  *) echo "Unknown variant: $VARIANT (use human|tor)" >&2; exit 2 ;;
esac

echo "Building $PACKAGE ${VERSION} (${ARCH}, variant=${VARIANT}, upstream ${BEARBROWSER_UPSTREAM_REF})..."

mkdir -p "$DEB_ROOT"
mkdir -p "$STAGE_DIR/usr/bin"
mkdir -p "$STAGE_DIR/usr/share/applications"
mkdir -p "$STAGE_DIR/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$STAGE_DIR/usr/share/metainfo"
mkdir -p "$STAGE_DIR/usr/lib/bearbrowser"

# ── Acquire the real binary tarball ───────────────────────────────────────────
# Prefer a tarball already staged in dist/linux/; otherwise pull it from GCS.
STAGED="$DIST_DIR/$TARBALL"
if [ ! -f "$STAGED" ]; then
  mkdir -p "$DIST_DIR"
  echo "Fetching real binary tarball from $BEARBROWSER_GCS_BASE/$TARBALL ..."
  if command -v gcloud >/dev/null 2>&1; then
    gcloud storage cp "$BEARBROWSER_GCS_BASE/$TARBALL" "$STAGED"
  else
    echo "ERROR: gcloud not found and no staged tarball at $STAGED" >&2
    echo "       Stage the tarball or install gcloud (auth required)." >&2
    exit 3
  fi
fi

# Verify integrity against the recorded SHA256.
ACTUAL_SHA="$( (sha256sum "$STAGED" 2>/dev/null || shasum -a 256 "$STAGED") | awk '{print $1}')"
if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
  echo "ERROR: SHA256 mismatch for $TARBALL" >&2
  echo "  expected $EXPECT_SHA" >&2
  echo "  actual   $ACTUAL_SHA" >&2
  exit 4
fi
echo "SHA256 verified: $ACTUAL_SHA"

# Extract the full Gecko runtime into /usr/lib/bearbrowser (tarball root is bin/).
tar -xzf "$STAGED" -C "$STAGE_DIR/usr/lib/bearbrowser"

LAUNCHER="$STAGE_DIR/usr/lib/bearbrowser/$BEARBROWSER_LAUNCHER_REL"
if [ ! -x "$LAUNCHER" ]; then
  chmod 0755 "$LAUNCHER" 2>/dev/null || true
fi
if [ ! -f "$LAUNCHER" ]; then
  echo "ERROR: launcher $BEARBROWSER_LAUNCHER_REL not found in tarball" >&2
  exit 5
fi

# Thin /usr/bin shim that points at the real launcher with a default profile.
cat > "$STAGE_DIR/usr/bin/bearbrowser" << EOF
#!/bin/sh
exec /usr/lib/bearbrowser/$BEARBROWSER_LAUNCHER_REL --profile "\$HOME/.bearbrowser/profiles/default" "\$@"
EOF
chmod 0755 "$STAGE_DIR/usr/bin/bearbrowser"

# Desktop file + metainfo
cp "$REPO_ROOT/packaging/linux/bearbrowser.desktop" "$STAGE_DIR/usr/share/applications/"

# Icon
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
echo "Built: $OUTPUT (real 140.12.0esr binary, variant=$VARIANT)"
