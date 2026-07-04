#!/usr/bin/env bash
set -euo pipefail

# Builds the native macOS WKWebView shell (native/macos/BearBrowserWebKitLauncher.m)
# into BearBrowser.app. Until now nothing in the repo compiled this into a bundle —
# it was done by hand, which is how the _serverTrust KVC crash shipped unnoticed.
# This makes it reproducible and gates on verify-native-macos-shell.sh first.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

version="0.1.0-overlay"
out_dir="$repo_root/build/macos-native"
do_install=""

usage() {
  cat <<'USAGE'
Usage: bearbrowser-build-native-shell [--version V] [--out-dir DIR] [--install]

Compiles the native macOS WKWebView shell into BearBrowser.app.

  --version   CFBundle version string.        Default: 0.1.0-overlay
  --out-dir   Output directory for the .app.  Default: build/macos-native
  --install   Also install to /Applications/BearBrowser.app (replaces binary,
              re-signs ad-hoc, clears quarantine).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version) version="${2:?missing version}"; shift 2 ;;
    --out-dir) out_dir="${2:?missing out-dir}"; shift 2 ;;
    --install) do_install="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: the native macOS shell only builds on macOS (Cocoa/WebKit)." >&2
  exit 1
fi

src="$repo_root/native/macos/BearBrowserWebKitLauncher.m"
landing="$repo_root/native/macos/BearBrowser-start.html"
fonts_dir="$repo_root/native/macos/fonts"
info_template="$repo_root/packaging/macos/Info.plist.template"
app="$out_dir/BearBrowser.app"

for f in "$src" "$landing" "$info_template"; do
  [ -f "$f" ] || { echo "ERROR: missing required input: $f" >&2; exit 1; }
done

# Gate: source contract + a throwaway compile must pass before we bundle anything.
echo "[1/6] Verifying native shell contract (verify-native-macos-shell.sh)..."
bash "$repo_root/scripts/verify-native-macos-shell.sh"

echo "[2/6] Compiling BearBrowserWebKitLauncher.m..."
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -fobjc-arc -O2 \
  -framework Cocoa -framework WebKit -framework AVFoundation -framework Security \
  "$src" -o "$app/Contents/MacOS/BearBrowser"

echo "[3/6] Rendering Info.plist (version=$version)..."
python3 - "$info_template" "$app/Contents/Info.plist" "$version" <<'PY'
from pathlib import Path
import sys
src, dst, version = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
text = src.read_text().replace('<string>0.1.0-overlay</string>', f'<string>{version}</string>')
dst.write_text(text)
PY

echo "[4/6] Installing bundle resources (start page, fonts, icon)..."
cp "$landing" "$app/Contents/Resources/BearBrowser-start.html"
[ -d "$fonts_dir" ] && cp -R "$fonts_dir" "$app/Contents/Resources/fonts"
# Icon: reuse the one already installed, or a packaged icns if present.
icon=""
for cand in "/Applications/BearBrowser.app/Contents/Resources/BearBrowser.icns" \
            "$repo_root/packaging/macos/BearBrowser.icns"; do
  [ -f "$cand" ] && { icon="$cand"; break; }
done
[ -n "$icon" ] && cp "$icon" "$app/Contents/Resources/BearBrowser.icns" || \
  echo "      note: no BearBrowser.icns found — bundle uses the default icon"

echo "[5/6] Signing (ad-hoc) + clearing quarantine..."
xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
codesign --force --sign - "$app" >/dev/null 2>&1 || \
  echo "      WARNING: ad-hoc signing returned non-zero (may still run)"

echo "[6/6] Built: $app"

if [ -n "$do_install" ]; then
  dest="/Applications/BearBrowser.app"
  echo "Installing to $dest ..."
  mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
  cp "$app/Contents/MacOS/BearBrowser" "$dest/Contents/MacOS/BearBrowser"
  cp "$app/Contents/Info.plist" "$dest/Contents/Info.plist"
  cp -R "$app/Contents/Resources/." "$dest/Contents/Resources/"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  codesign --force --sign - "$dest" >/dev/null 2>&1 || true
  echo "Installed: $dest  (relaunch it)"
fi
