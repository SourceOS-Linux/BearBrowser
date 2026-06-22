#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
ref="latest"
dry_run="false"
compile="true"
execute_compile="false"
workspace_root="build/workspaces"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
metadata_out="build/release-metadata/bearbrowser-${profile}-release-metadata.json"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-build-binary [--profile human-secure|agent-runtime] [--ref latest|tag|sha|branch] [--dry-run] [--no-compile] [--execute-compile]

Prepares the full LibreWolf-derived BearBrowser binary build lane.

Steps:
  Applies SourceOS/BearBrowser overlays into a generated workspace, emits
  release metadata, then invokes the LibreWolf (Firefox) mach compile step.

Options:
  --no-compile       Stop after overlays + metadata; skip the compile step.
  --execute-compile  Pass --execute to the compile step (runs a real, expensive
                     mach build). Without it, the compile step only prints the
                     planned mach commands (dry run) — even on a full lane run.
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
    --no-compile)
      compile="false"
      shift
      ;;
    --execute-compile)
      execute_compile="true"
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

metadata_out="build/release-metadata/bearbrowser-${profile}-release-metadata.json"

echo "BearBrowser full binary build lane"
echo "profile=$profile"
echo "ref=$ref"
echo "workspace_root=$workspace_root"
echo "metadata_out=$metadata_out"
echo "dry_run=$dry_run"

bash scripts/verify-upstream-parity.sh

if [ "$dry_run" = "true" ]; then
  bash scripts/apply-sourceos-overlays.sh --profile "$profile" --ref "$ref" --workspace-root "$workspace_root" --dry-run
  bash scripts/emit-release-metadata.sh --profile "$profile" --upstream-ref "$ref" --out "$metadata_out"
  echo "Dry run complete. Full LibreWolf compile step is not wired yet."
  exit 0
fi

bash scripts/apply-sourceos-overlays.sh --profile "$profile" --ref "$ref" --workspace-root "$workspace_root"
bash scripts/emit-release-metadata.sh --profile "$profile" --upstream-ref "$ref" --out "$metadata_out"

echo
echo "Generated overlay workspace and release metadata are ready."
echo "Metadata: $metadata_out"

if [ "$compile" = "false" ]; then
  echo "Compile skipped (--no-compile). Overlay workspace + metadata are ready."
  exit 0
fi

workspace="$(ls -dt "$repo_root"/build/workspaces/${profile}-* 2>/dev/null | head -1)"
if [ -z "$workspace" ]; then
  echo "ERROR: could not locate generated workspace" >&2
  exit 1
fi

compile_args=(--workspace "$workspace" --profile "$profile")
if [ "$execute_compile" = "true" ]; then
  compile_args+=(--execute)
fi
bash "$repo_root/scripts/build-in-workspace.sh" "${compile_args[@]}"
