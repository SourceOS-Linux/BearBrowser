#!/usr/bin/env bash
set -euo pipefail

target="/Applications/BearBrowser.app"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

usage() {
  cat <<'USAGE'
Usage: repair-macos-app-launcher [--target /Applications/BearBrowser.app]

Repairs BearBrowser.app so the running Dock process is BearBrowser, not Firefox.
Installs a native macOS WebKit bootstrap shell inside the app bundle.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      target="${2:?missing target app path}"
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

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: this command is only supported on macOS" >&2
  exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang is required to build the BearBrowser native launcher" >&2
  exit 2
fi

native_source="$repo_root/native/macos/BearBrowserWebKitLauncher.m"
native_landing="$repo_root/native/macos/BearBrowser-start.html"

if [ ! -f "$native_source" ]; then
  echo "ERROR: missing native shell source: $native_source" >&2
  exit 1
fi

if [ ! -f "$native_landing" ]; then
  echo "ERROR: missing native start page: $native_landing" >&2
  exit 1
fi

contents="$target/Contents"
resources="$contents/Resources"
macos="$contents/MacOS"
mkdir -p "$resources" "$macos"

plist="$contents/Info.plist"
exe="$macos/BearBrowser"

cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BearBrowser</string>
  <key>CFBundleDisplayName</key><string>BearBrowser</string>
  <key>CFBundleIdentifier</key><string>dev.sourceos.BearBrowser</string>
  <key>CFBundleExecutable</key><string>BearBrowser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>BearBrowser</string>
  <key>CFBundleShortVersionString</key><string>0.1.0-overlay</string>
  <key>CFBundleVersion</key><string>0.1.0-overlay</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp "$native_landing" "$resources/BearBrowser-start.html"
cp "$native_source" "$resources/BearBrowserWebKitLauncher.m"

clang -fobjc-arc -framework Cocoa -framework WebKit "$resources/BearBrowserWebKitLauncher.m" -o "$exe"
chmod +x "$exe"
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
  "$lsregister" -f "$target" || true
fi

/usr/bin/touch "$target"
echo "Repaired BearBrowser app launcher with native WebKit executable: $target"
echo "Open: open '$target'"
echo "Log: ~/Library/Logs/BearBrowser/launcher.log"
