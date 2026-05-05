#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prov="$tmp/events.jsonl"
actions="$tmp/actions.jsonl"
html="$tmp/status.html"
json="$tmp/status.json"

python3 scripts/bearbrowser-emit-event.py \
  --event-type app.launch \
  --surface native-shell \
  --profile bootstrap \
  --actor-type human \
  --actor-id ci \
  --decision allow \
  --policy-mode local-default \
  --payload '{"app":"BearBrowser","launcher":"ci"}' \
  --out "$prov" >/dev/null

python3 scripts/bearbrowser-propose-action.py \
  --action-type share_page_with_agent \
  --profile bootstrap \
  --actor-type human \
  --actor-id ci \
  --target-kind page \
  --target-label current-page \
  --out "$actions" >/dev/null

python3 scripts/bearbrowser-sidecar-status.py \
  --events "$prov" \
  --actions "$actions" \
  --format text

python3 scripts/bearbrowser-sidecar-status.py \
  --events "$prov" \
  --actions "$actions" \
  --format json > "$json"

python3 scripts/bearbrowser-sidecar-status.py \
  --events "$prov" \
  --actions "$actions" \
  --format html \
  --out "$html"

test -f "$json"
test -f "$html"
grep -q 'BearBrowser Sidecar Status' "$html"
grep -q 'local-sidecar-ready' "$json"
grep -q 'share_page_with_agent' "$html"

echo "BearBrowser sidecar status verified"
