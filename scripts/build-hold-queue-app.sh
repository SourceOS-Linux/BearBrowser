#!/usr/bin/env bash
# Build BearBrowserPolicyQueue — native macOS status bar app for PolicyFabric hold decisions.
#
# Usage: bash scripts/build-hold-queue-app.sh [--install]
#   --install   copy the binary to /usr/local/bin/BearBrowserPolicyQueue after building

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/native/macos/BearBrowserPolicyQueue.swift"
OUT_DIR="$REPO_ROOT/build"
BINARY="$OUT_DIR/BearBrowserPolicyQueue"

mkdir -p "$OUT_DIR"

echo "==> Building BearBrowserPolicyQueue..."
swiftc \
    -framework Cocoa \
    -O \
    "$SRC" \
    -o "$BINARY"

echo "==> Built: $BINARY"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /usr/local/bin/BearBrowserPolicyQueue"
    cp "$BINARY" /usr/local/bin/BearBrowserPolicyQueue
    chmod +x /usr/local/bin/BearBrowserPolicyQueue
    echo "==> Installed."
fi

echo ""
echo "To run:"
echo "  $BINARY"
echo ""
echo "To uninstall from login items: System Settings → General → Login Items"
