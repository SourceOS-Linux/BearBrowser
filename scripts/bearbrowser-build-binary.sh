#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
ref="latest"
dry_run="false"
workspace_root="build/workspaces"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-build-binary [--profile human-secure|agent-runtime] [--ref latest|tag|sha|branch] [--dry-run]

Prepares the full LibreWolf-derived BearBrowser binary build lane.

Current status:
  This command creates or dry-runs the generated overlay workspace and emits the
  expected build metadata path. It does not yet compile the full LibreWolf browser.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      profile="${2:?missing profile}"
      shift 2
      ;;
    --ref)
      ref="${2:?missing ref}"
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

case "$profile" in
  human-secure|agent-runtime) ;;
  *)
    echo "ERROR: invalid profile: $profile" >&2
    exit 1
    ;;
esac

echo "BearBrowser full binary build lane"
echo "profile=$profile"
echo "ref=$ref"
echo "workspace_root=$workspace_root"
echo "dry_run=$dry_run"

bash scripts/verify-upstream-parity.sh

if [ "$dry_run" = "true" ]; then
  bash scripts/apply-sourceos-overlays.sh --profile "$profile" --ref "$ref" --workspace-root "$workspace_root" --dry-run
  echo "Dry run complete. Full LibreWolf compile step is not wired yet."
  exit 0
fi

bash scripts/apply-sourceos-overlays.sh --profile "$profile" --ref "$ref" --workspace-root "$workspace_root"

echo
echo "Generated overlay workspace is ready."
echo "Next implementation step: invoke LibreWolf build tooling inside the generated workspace and emit release metadata."
echo "This command intentionally exits 64 until the real browser compile step is implemented."
exit 64
