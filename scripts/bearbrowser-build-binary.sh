#!/usr/bin/env bash
set -euo pipefail

profile="human-secure"
ref="latest"
dry_run="false"
workspace_root="build/workspaces"
lane="source"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
metadata_out="build/release-metadata/bearbrowser-${profile}-release-metadata.json"

artifact_out=""

usage() {
  cat <<'USAGE'
Usage: bearbrowser-build-binary [--lane source|overlay] [--profile human-secure|agent-runtime]
                                 [--ref latest|tag|sha|branch] [--artifact-out DIR] [--dry-run]

Builds a BearBrowser binary. Two lanes are available:

  --lane overlay  (fast, default for dogfood)
    Downloads the LibreWolf base binary via Homebrew, applies BearBrowser branding
    and policy overlays, and produces BearBrowser.app in build/macos-overlay/.
    Ready in minutes. Ad-hoc signed. macOS only.

  --lane source   (full build, for production releases)
    Clones the upstream LibreWolf mirror, applies patches and branding overlays,
    then runs ./mach build to compile the full Gecko browser.
    Takes 30–90 minutes. Requires a full Firefox build environment.

Steps (overlay lane):
  1. Fetch LibreWolf base binary via Homebrew.
  2. Apply BearBrowser branding and identity overlays.
  3. Inject profile settings (user.js, policies.json).
  4. Ad-hoc sign, verify identity.

Steps (source lane):
  1. Check build environment.
  2. Verify upstream mirror parity.
  3. Generate overlay workspace (clone mirror, apply patches, apply branding).
  4. Emit release metadata.
  5. Discover upstream build system markers.
  6. Invoke ./mach build inside the workspace.
  7. Copy artifacts to --artifact-out if specified.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane)
      lane="${2:?missing lane}"
      shift 2
      ;;
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
    --artifact-out)
      artifact_out="${2:?missing artifact-out path}"
      shift 2
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

case "$lane" in
  overlay|source) ;;
  *)
    echo "ERROR: invalid lane '$lane'. Expected overlay or source." >&2
    exit 1
    ;;
esac

metadata_out="$repo_root/build/release-metadata/bearbrowser-${profile}-release-metadata.json"

# ── Overlay lane (fast path) ──────────────────────────────────────────────────
if [ "$lane" = "overlay" ]; then
  echo "BearBrowser binary build — overlay lane"
  echo "profile=$profile"
  echo "dry_run=$dry_run"
  echo

  if [ "$dry_run" = "true" ]; then
    echo "Overlay lane steps:"
    echo "  1. bearbrowser-fetch-librewolf-base"
    echo "  2. bearbrowser-overlay-binary --profile $profile"
    echo "  3. Output: build/macos-overlay/BearBrowser.app"
    echo "Dry run complete."
    exit 0
  fi

  # Step 1: Fetch LibreWolf base binary via Homebrew.
  echo "[overlay 1/2] Fetching LibreWolf base binary..."
  librewolf_app="$(bash "$script_dir/bearbrowser-fetch-librewolf-base.sh" --print-path | tail -1)"
  if [ -z "$librewolf_app" ] || [ ! -d "$librewolf_app" ]; then
    echo "ERROR: could not locate LibreWolf.app after fetch." >&2
    exit 1
  fi
  echo "  base: $librewolf_app"

  # Step 2: Apply BearBrowser overlays.
  echo "[overlay 2/2] Applying BearBrowser overlays..."
  overlay_args=(--input-app "$librewolf_app" --profile "$profile")
  if [ -n "$artifact_out" ]; then
    overlay_args+=(--out-dir "$artifact_out")
  fi
  bash "$script_dir/bearbrowser-overlay-binary.sh" "${overlay_args[@]}"
  exit 0
fi

# ── Source lane (full Gecko build) ────────────────────────────────────────────

echo "BearBrowser full binary build lane"
echo "repo_root=$repo_root"
echo "profile=$profile"
echo "ref=$ref"
echo "workspace_root=$workspace_root"
echo "metadata_out=$metadata_out"
echo "dry_run=$dry_run"

bash "$repo_root/scripts/check-build-environment.sh"
bash "$repo_root/scripts/verify-upstream-parity.sh"

if [ "$dry_run" = "true" ]; then
  bash "$repo_root/scripts/apply-sourceos-overlays.sh" --profile "$profile" --ref "$ref" --workspace-root "$workspace_root" --dry-run
  bash "$repo_root/scripts/emit-release-metadata.sh" --profile "$profile" --upstream-ref "$ref" --out "$metadata_out"
  echo "Dry run complete."
  exit 0
fi

bash "$repo_root/scripts/apply-sourceos-overlays.sh" --profile "$profile" --ref "$ref" --workspace-root "$workspace_root"
bash "$repo_root/scripts/emit-release-metadata.sh" --profile "$profile" --upstream-ref "$ref" --out "$metadata_out"

safe_ref="$(printf '%s' "$ref" | tr '/:@' '---')"
if [ "$ref" = "latest" ]; then
  # Read the generated workspace from the latest overlay output.
  workspace_source="$(find "$repo_root/$workspace_root" -maxdepth 2 -type d -name source | sort | tail -1)"
else
  workspace_source="$repo_root/$workspace_root/${profile}-${safe_ref}/source"
fi

if [ -d "$workspace_source" ]; then
  bash "$repo_root/scripts/discover-upstream-build-system.sh" "$workspace_source"
else
  echo "ERROR: generated workspace source not found for build-system discovery" >&2
  exit 1
fi

echo
echo "Generated overlay workspace and release metadata are ready."
echo "Metadata: $metadata_out"
echo "Workspace source: $workspace_source"
echo

invoke_build_args=(
  --workspace "$workspace_source"
  --profile "$profile"
)
if [ -n "$artifact_out" ]; then
  invoke_build_args+=(--artifact-out "$artifact_out")
fi

bash "$repo_root/scripts/bearbrowser-invoke-build.sh" "${invoke_build_args[@]}"
