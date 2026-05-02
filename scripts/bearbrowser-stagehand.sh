#!/usr/bin/env bash
set -euo pipefail

operation="observe"
dry_run="false"
url="about:blank"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-stagehand [--operation observe|extract|recover] [--url URL] [--dry-run]

Stagehand compatibility surface for BearBrowser.

This command currently reports the intended policy and provenance envelope for
future Stagehand integration. Live browser execution is not enabled in this
scaffold.
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
liveExecution=disabled
EOF

if ! command -v node >/dev/null 2>&1; then
  echo "missing: node"
  echo "Install Node or use the BearBrowser Brewfile before enabling Stagehand compatibility checks."
  exit 2
fi

if [ "$dry_run" = "true" ]; then
  echo "Dry run complete."
  exit 0
fi

echo "Live Stagehand integration is not implemented in this scaffold yet."
exit 64
