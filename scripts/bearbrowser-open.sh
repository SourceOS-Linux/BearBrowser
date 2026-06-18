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

# Launch policy queue status bar app if available and not already running.
# Looks for binary in: build/ (dev), /usr/local/bin (installed), or BEARBROWSER_HOME/build/.
_pq_binary=""
for _candidate in \
    "${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}/build/BearBrowserPolicyQueue" \
    "/usr/local/bin/BearBrowserPolicyQueue"; do
  if [ -x "$_candidate" ]; then
    _pq_binary="$_candidate"
    break
  fi
done

if [ -n "$_pq_binary" ]; then
  if ! pgrep -qx BearBrowserPolicyQueue 2>/dev/null; then
    nohup "$_pq_binary" >/dev/null 2>&1 &
    echo "Started BearBrowser policy queue: $_pq_binary (PID $!)"
  else
    echo "Policy queue already running."
  fi
else
  echo "Policy queue binary not found — run: bash scripts/build-hold-queue-app.sh"
fi

# Sync any BearBlocker receipts accumulated since last launch into events.jsonl.
python3 "$script_dir/bearbrowser-sync-blocker-receipts.py" 2>/dev/null || true

echo "Opened BearBrowser: $app"
echo "Run status: bearbrowser-status"
echo "Verify provenance: bearbrowser-verify-provenance"
