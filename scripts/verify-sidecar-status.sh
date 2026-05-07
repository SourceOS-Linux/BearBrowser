#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prov="$tmp/events.jsonl"
actions="$tmp/actions.jsonl"
memory="$tmp/memory.jsonl"
summaries="$tmp/summaries.jsonl"
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

python3 scripts/bearbrowser-memory-candidate.py create \
  --text "Remember that sidecar status renders pending memory candidates." \
  --actor-type human \
  --actor-id ci \
  --source-kind note \
  --source-label ci-sidecar-memory \
  --memory-log "$memory" \
  --event-log "$prov" >/dev/null

python3 scripts/bearbrowser-page-summary.py create \
  --text "BearBrowser summary status renders read-only page summary proposals." \
  --actor-type human \
  --actor-id ci \
  --source-kind page \
  --source-label ci-sidecar-summary \
  --summary-log "$summaries" \
  --event-log "$prov" \
  --action-log "$actions" >/dev/null

python3 scripts/bearbrowser-sidecar-status.py \
  --events "$prov" \
  --actions "$actions" \
  --memory "$memory" \
  --summaries "$summaries" \
  --format text

python3 scripts/bearbrowser-sidecar-status.py \
  --events "$prov" \
  --actions "$actions" \
  --memory "$memory" \
  --summaries "$summaries" \
  --format json > "$json"

python3 scripts/bearbrowser-sidecar-status.py \
  --events "$prov" \
  --actions "$actions" \
  --memory "$memory" \
  --summaries "$summaries" \
  --format html \
  --out "$html"

test -f "$json"
test -f "$html"
grep -q 'BearBrowser Sidecar Status' "$html"
grep -q 'local-sidecar-ready' "$json"
grep -q 'share_page_with_agent' "$html"
grep -q 'Pending Memory Candidates' "$html"
grep -q 'ci-sidecar-memory' "$html"
grep -q 'Recent Page Summaries' "$html"
grep -q 'ci-sidecar-summary' "$html"
grep -q '"pendingMemoryCount": 1' "$json"
grep -q '"summaryCount": 1' "$json"

echo "BearBrowser sidecar status verified"
