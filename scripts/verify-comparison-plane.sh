#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prov="$tmp/events.jsonl"
actions="$tmp/actions.jsonl"
comparisons="$tmp/comparisons.jsonl"
left="$tmp/left.txt"
right="$tmp/right.txt"

cat > "$left" <<'TEXT'
BearBrowser provides a local governed browser surface with provenance records, held policy actions, and explicit user resolution.
TEXT

cat > "$right" <<'TEXT'
The SourceOS browser work emphasizes local governance, auditable policy decisions, provenance records, and explicit sidecar review.
TEXT

python3 scripts/bearbrowser-page-comparison.py create \
  --left-text-file "$left" \
  --right-text-file "$right" \
  --left-kind page \
  --right-kind page \
  --left-label bearbrowser-governance \
  --right-label sourceos-governance \
  --left-url https://example.invalid/bearbrowser \
  --right-url https://example.invalid/sourceos \
  --actor-type human \
  --actor-id ci \
  --comparison-log "$comparisons" \
  --event-log "$prov" \
  --action-log "$actions" \
  >/dev/null

python3 scripts/bearbrowser-page-comparison.py create \
  --left-text "sensitive token example must not be persisted" \
  --right-text "comparison right side" \
  --left-kind page \
  --right-kind note \
  --left-label sensitive-left \
  --right-label safe-right \
  --actor-type human \
  --actor-id ci \
  --comparison-log "$comparisons" \
  --event-log "$prov" \
  --action-log "$actions" \
  >/dev/null

python3 scripts/bearbrowser-verify-comparisons.py --log "$comparisons"
python3 scripts/bearbrowser-verify-actions.py --log "$actions"
python3 scripts/bearbrowser-verify-provenance.py --log "$prov"

grep -q '"actionType":"compare_tabs"' "$actions"
grep -q '"state":"hold"' "$actions"
grep -q '"eventType":"page.shared_with_agent"' "$prov"
grep -q '"comparisonId"' "$prov"
grep -q 'Shared terms:' "$comparisons"
grep -q '<REDACTED-SENSITIVE-COMPARISON-EXCERPT>' "$comparisons"
if grep -q 'sensitive token example must not be persisted' "$comparisons"; then
  echo "ERROR: sensitive comparison text escaped redaction" >&2
  exit 1
fi

echo "BearBrowser comparison plane verified"
echo "comparison_log=$comparisons"
echo "policy_action_log=$actions"
echo "provenance_log=$prov"
