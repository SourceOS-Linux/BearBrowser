#!/usr/bin/env bash
set -euo pipefail

app="${BEARBROWSER_APP:-/Applications/BearBrowser.app}"
log="$HOME/Library/Logs/BearBrowser/launcher.log"
profile="$HOME/Library/Application Support/BearBrowser/profile"
landing="$app/Contents/Resources/BearBrowser-start.html"
exe="$app/Contents/MacOS/BearBrowser"

echo "BearBrowser status"
echo "app=$app"

if [ -d "$app" ]; then
  echo "ok: app bundle exists"
else
  echo "missing: app bundle"
fi

if [ -x "$exe" ]; then
  echo "ok: executable exists -> $exe"
  if command -v file >/dev/null 2>&1; then
    echo "executable_type=$(file -b "$exe")"
  fi
else
  echo "missing: executable -> $exe"
fi

if [ -f "$app/Contents/Info.plist" ]; then
  echo "ok: Info.plist exists"
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    bundle_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$app/Contents/Info.plist" 2>/dev/null || true)"
    executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
    echo "bundle_id=${bundle_id:-unknown}"
    echo "bundle_name=${bundle_name:-unknown}"
    echo "bundle_executable=${executable:-unknown}"
  fi
else
  echo "missing: Info.plist"
fi

if [ -f "$app/Contents/Resources/BearBrowser.icns" ]; then
  echo "ok: icon exists"
else
  echo "missing: icon"
fi

if [ -f "$landing" ]; then
  echo "ok: native shell landing page exists"
else
  echo "missing: native shell landing page"
fi

if [ -d "$profile" ]; then
  echo "ok: BearBrowser bootstrap profile exists"
else
  echo "missing: BearBrowser bootstrap profile"
fi

echo
printf 'Running BearBrowser processes:\n'
if pgrep -fl "/Applications/BearBrowser.app/Contents/MacOS/BearBrowser" >/dev/null 2>&1; then
  pgrep -fl "/Applications/BearBrowser.app/Contents/MacOS/BearBrowser" || true
else
  echo "none"
fi

echo
printf 'Old Firefox bootstrap processes using BearBrowser profile:\n'
if pgrep -fl "Application Support/BearBrowser/profile" >/dev/null 2>&1; then
  pgrep -fl "Application Support/BearBrowser/profile" || true
else
  echo "none"
fi

echo
printf 'Default Firefox processes, if any:\n'
if pgrep -fl "/Applications/Firefox.app/Contents/MacOS/firefox" >/dev/null 2>&1; then
  pgrep -fl "/Applications/Firefox.app/Contents/MacOS/firefox" || true
else
  echo "none"
fi

echo
if [ -f "$log" ]; then
  echo "Launcher log tail: $log"
  tail -40 "$log" || true
else
  echo "missing: launcher log -> $log"
fi
