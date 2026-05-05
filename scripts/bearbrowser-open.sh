#!/usr/bin/env bash
set -euo pipefail

app="${BEARBROWSER_APP:-/Applications/BearBrowser.app}"

if [ ! -d "$app" ]; then
  echo "BearBrowser.app is not installed at: $app" >&2
  echo "Run: bearbrowser-install-app-launcher" >&2
  exit 1
fi

if [ ! -x "$app/Contents/MacOS/BearBrowser" ]; then
  echo "BearBrowser.app executable is missing or not executable." >&2
  echo "Run: bearbrowser-repair-app-launcher" >&2
  exit 1
fi

open "$app"

echo "Opened BearBrowser: $app"
echo "Run status: bearbrowser-status"
