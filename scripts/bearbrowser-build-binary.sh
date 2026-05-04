#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
ref="latest"
dry_run="false"
workspace_root="build/workspaces"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
metadata_out="build/release-metadata/bearbrowser-${profile}-release-metadata.json"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-build-binary [--profile human-secure|agent-runtime] [--ref latest|tag|sha|branch] [--dry-run]

Prepares the full BearBrowser binary build lane.

Current status:
  This command creates or dry-runs the generated overlay workspace and emits
  release metadata. It does not yet compile the full browser.
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

metadata_out="$repo_root/build/release-metadata/bearbrowser-${profile}-release-metadata.json"

echo "BearBrowser full binary build lane"
echo "repo_root=$repo_root"
echo "profile=$profile"
echo "ref=$ref"
echo "workspace_root=$workspace_root"
echo "metadata_out=$metadata_out"
echo "dry_run=$dry_run"

bash "$repo_root/scripts/verify-upstream-parity.sh"

if [ "$dry_run" = "true" ]; then
  bash "$repo_root/scripts/apply-sourceos-overlays.sh" --profile "$profile" --ref "$ref" --workspace-root "$workspace_root" --dry-run
  bash "$repo_root/scripts/emit-release-metadata.sh" --profile "$profile" --upstream-ref "$ref" --out "$metadata_out"
  echo "Dry run complete. Full browser compile step is not wired yet."
  exit 0
fi

bash "$repo_root/scripts/apply-sourceos-overlays.sh" --profile "$profile" --ref "$ref" --workspace-root "$workspace_root"
bash "$repo_root/scripts/emit-release-metadata.sh" --profile "$profile" --upstream-ref "$ref" --out "$metadata_out"

echo
echo "Generated overlay workspace and release metadata are ready."
echo "Metadata: $metadata_out"
echo "Next implementation step: invoke browser build tooling inside the generated workspace."
echo "This command intentionally exits 64 until the real browser compile step is implemented."
exit 64
