#!/usr/bin/env bash
set -euo pipefail

operation="observe"
dry_run="false"
url="about:blank"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-stagehand [--operation observe|extract|recover] [--url URL] [--dry-run]

Stagehand compatibility surface for BearBrowser.

Dry-run validates the policy/provenance envelope and Stagehand dependency.
Live execution remains guarded until provider credentials and PolicyFabric
adapter integration are complete.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --operation)
      operation="${2:?missing operation}"
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

case "$operation" in
  observe|extract|recover) ;;
  *)
    echo "ERROR: invalid operation: $operation" >&2
    exit 1
    ;;
esac

cat <<EOF
BearBrowser Stagehand adapter
operation=$operation
url=$url
policy=PolicyFabric
provenance=required
observationBeforeMutation=required
EOF

if ! command -v node >/dev/null 2>&1; then
  echo "missing: node"
  echo "Install Node or use the BearBrowser Brewfile before enabling Stagehand compatibility checks."
  exit 2
fi

if [ ! -d "$repo_root/node_modules/@browserbasehq/stagehand" ]; then
  echo "missing: @browserbasehq/stagehand runtime dependency"
  echo "Run npm install in the BearBrowser repo, or install a packaged runtime distribution."
  if [ "$dry_run" = "true" ]; then
    echo "Dry run dependency check complete."
    exit 2
  fi
  exit 2
fi

export BEARBROWSER_URL="$url"
export BEARBROWSER_STAGEHAND_OPERATION="$operation"
if [ "$dry_run" = "true" ]; then
  unset BEARBROWSER_ENABLE_LIVE_STAGEHAND
fi

exec node "$repo_root/runtime/stagehand-check.mjs"
