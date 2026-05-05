#!/usr/bin/env bash
set -euo pipefail

app="${BEARBROWSER_APP:-/Applications/BearBrowser.app}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

python3 "$script_dir/bearbrowser-emit-event.py" \
  --event-type app.launch \
  --surface native-shell \
  --profile bootstrap \
  --actor-type human \
  --actor-id "${USER:-local-user}" \
  --decision allow \
  --policy-mode local-default \
  --policy-reason "User requested BearBrowser native shell launch." \
  --payload "{\"app\":\"$app\",\"launcher\":\"bearbrowser-open\"}" >/dev/null

open "$app"

echo "Opened BearBrowser: $app"
echo "Run status: bearbrowser-status"
echo "Verify provenance: bearbrowser-verify-provenance"
