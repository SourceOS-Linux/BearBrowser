#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prov="$tmp/events.jsonl"
actions="$tmp/actions.jsonl"

python3 scripts/bearbrowser-emit-event.py \
  --event-type runtime.health \
  --surface native-shell \
  --profile bootstrap \
  --actor-type system \
  --actor-id ci \
  --decision observe \
  --policy-mode local-default \
  --payload '{"status":"ok","token":"must-redact"}' \
  --out "$prov"

python3 scripts/bearbrowser-emit-event.py \
  --event-type credential.requested \
  --surface credential-broker \
  --profile agent-runtime \
  --actor-type agent \
  --actor-id ci-agent \
  --decision deny \
  --policy-mode local-default \
  --payload '{"credential":"must-redact","url":"https://example.invalid/login"}' \
  --out "$prov"

python3 scripts/bearbrowser-verify-provenance.py --log "$prov"

grep -q '<REDACTED>' "$prov"
if grep -q 'must-redact' "$prov"; then
  echo "ERROR: secret-like value escaped provenance redaction" >&2
  exit 1
fi

python3 scripts/bearbrowser-propose-action.py \
  --action-type summarize_page \
  --profile bootstrap \
  --actor-type human \
  --actor-id ci \
  --target-kind page \
  --target-label current-page \
  --out "$actions"

python3 scripts/bearbrowser-propose-action.py \
  --action-type share_page_with_agent \
  --profile bootstrap \
  --actor-type human \
  --actor-id ci \
  --target-kind page \
  --target-label current-page \
  --out "$actions"

python3 scripts/bearbrowser-propose-action.py \
  --action-type request_credential \
  --profile agent-runtime \
  --actor-type agent \
  --actor-id ci-agent \
  --target-kind credential \
  --target-label login-form \
  --out "$actions"

python3 scripts/bearbrowser-resolve-action.py \
  --actions "$actions" \
  --events "$prov" \
  --latest-held \
  --decision deny \
  --actor-type human \
  --actor-id ci-reviewer \
  --reason "CI denies held test action." \
  >/dev/null

python3 scripts/bearbrowser-verify-actions.py --log "$actions"
python3 scripts/bearbrowser-verify-provenance.py --log "$prov"

grep -q '"state":"observe"' "$actions"
grep -q '"state":"deny"' "$actions"
grep -q '"eventType":"policy.decision"' "$prov"
grep -q '"mode":"manual"' "$prov"

echo "BearBrowser feature plane verified"
echo "provenance_log=$prov"
echo "policy_action_log=$actions"
