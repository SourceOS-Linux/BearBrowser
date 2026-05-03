#!/usr/bin/env bash
set -euo pipefail

mode="agent-runtime"
dry_run="false"
url="about:blank"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-playwright [--mode agent-runtime|human-secure] [--url URL] [--dry-run]

Policy-mediated Playwright control surface for BearBrowser.

Dry-run works after Homebrew install. Live execution requires:
  BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT=1
  BEARBROWSER_POLICY_DECISION_ID=<policy-decision-id>
  npm install
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

export BEARBROWSER_MODE="$mode"
export BEARBROWSER_URL="$url"
exec node "$repo_root/runtime/playwright-smoke.mjs"
