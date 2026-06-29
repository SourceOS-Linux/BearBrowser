#!/usr/bin/env bash
set -euo pipefail

mode="agent-runtime"
dry_run="false"
url="about:blank"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script_dir="$repo_root/scripts"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-playwright [--mode agent-runtime|human-secure] [--url URL] [--dry-run]

Policy-mediated Playwright control surface for BearBrowser.

Dry-run works after Homebrew install. Live execution requires:
  BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT=1
  BEARBROWSER_POLICY_DECISION_ID=<policy-decision-id>
  npm install

A BrowserAutomationReceipt is created before every live session and updated
on completion (status=ended) or failure (status=failed).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      mode="${2:?missing mode}"
      shift 2
      ;;
    --url)
      url="${2:?missing url}"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
      shift
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

case "$mode" in
  agent-runtime|human-secure) ;;
  *)
    echo "ERROR: invalid mode: $mode" >&2
    exit 1
    ;;
esac

cat <<EOF
BearBrowser Playwright adapter
mode=$mode
url=$url
policy=PolicyFabric
provenance=required-for-agent-runtime
authority=not-granted-by-wrapper
remoteDebuggingDefault=denied
EOF

if [ "$dry_run" = "true" ]; then
  if command -v node >/dev/null 2>&1; then
    echo "ok: node -> $(command -v node)"
  else
    echo "optional-missing: node"
  fi
  if [ -d "$repo_root/node_modules/playwright" ]; then
    echo "ok: playwright runtime dependency present"
  else
    echo "optional-missing: playwright runtime dependency"
  fi
  echo "Dry run complete. Live launch would be policy-mediated."
  exit 0
fi

# --- Live execution: obtain a policy decision ---
# If BEARBROWSER_POLICY_DECISION_ID is already set, use it (caller-supplied decision).
# Otherwise, call the local policy engine to get a decision for run_automation.
# The engine returns exit code 0 (allow), 2 (hold), or 3 (deny).
if [ -z "${BEARBROWSER_POLICY_DECISION_ID:-}" ]; then
  echo "No BEARBROWSER_POLICY_DECISION_ID set — requesting local policy decision..."
  _policy_out=""
  _policy_exit=0
  _policy_out="$(python3 "$script_dir/bearbrowser-policy-engine.py" \
    --action run_automation --profile "$mode" 2>&1)" || _policy_exit=$?

  _decision_id="$(echo "$_policy_out" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d.get('decisionId',''))" 2>/dev/null || true)"

  if [ "$_policy_exit" -eq 3 ]; then
    echo "DENIED: policy engine denied automation for profile=$mode" >&2
    echo "$_policy_out" >&2
    exit 3
  elif [ "$_policy_exit" -eq 2 ]; then
    echo "HELD: policy engine placed automation on hold for profile=$mode" >&2
    echo "  Resolve via: bearbrowser-resolve-action --decision-id <id> --resolution allow" >&2
    echo "$_policy_out" >&2
    exit 2
  elif [ "$_policy_exit" -ne 0 ]; then
    echo "ERROR: policy engine returned unexpected exit code $_policy_exit" >&2
    echo "$_policy_out" >&2
    exit 1
  fi

  if [ -z "$_decision_id" ]; then
    echo "ERROR: policy engine did not return a decisionId" >&2
    exit 1
  fi

  export BEARBROWSER_POLICY_DECISION_ID="$_decision_id"
  echo "Policy decision granted: $BEARBROWSER_POLICY_DECISION_ID"
fi

if ! command -v node >/dev/null 2>&1; then
  echo "missing: node"
  echo "Install Node or use the BearBrowser Brewfile before enabling Playwright automation."
  exit 2
fi

if [ ! -d "$repo_root/node_modules/playwright" ]; then
  echo "missing: playwright runtime dependency"
  echo "Run npm install in the BearBrowser repo, or install a packaged runtime distribution."
  exit 2
fi

# --- Create automation receipt ---
_owner="${BEARBROWSER_AGENT_ID:-human}"
_receipt_output=""
if ! _receipt_output="$(python3 "$script_dir/bearbrowser-create-receipt.py" \
      --transport cdp \
      --mode "$mode" \
      --url "$url" \
      --decision-id "$BEARBROWSER_POLICY_DECISION_ID" \
      --owner "$_owner" 2>&1)"; then
  echo "ERROR: failed to create automation receipt:" >&2
  echo "$_receipt_output" >&2
  exit 1
fi

_receipt_id="$(echo "$_receipt_output" | head -1)"
echo ""
echo "BearBrowser automation receipt created"
echo "  receiptId=$_receipt_id"
echo "$_receipt_output" | tail -n +2
echo ""

# --- Run Playwright session; update receipt on completion ---
export BEARBROWSER_MODE="$mode"
export BEARBROWSER_URL="$url"
export BEARBROWSER_RECEIPT_ID="$_receipt_id"

_exit_code=0
node "$repo_root/runtime/playwright-smoke.mjs" || _exit_code=$?

if [ "$_exit_code" -eq 0 ]; then
  _update_status="ended"
else
  _update_status="failed"
fi

if ! python3 "$script_dir/bearbrowser-update-receipt.py" \
      --receipt-id "$_receipt_id" \
      --status "$_update_status" >/dev/null 2>&1; then
  echo "WARNING: could not update receipt status to ${_update_status} for ${_receipt_id}" >&2
fi

echo ""
echo "BearBrowser session ${_update_status} (receiptId=${_receipt_id})"
exit "$_exit_code"
