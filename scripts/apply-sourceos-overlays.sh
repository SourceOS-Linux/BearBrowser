#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
ref="latest"
dry_run="false"
workspace_root="build/workspaces"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
manifest_file="$repo_root/manifests/upstream.json"

mirror_from_manifest() {
  if [ -f "$manifest_file" ]; then
    python3 - <<PY
import json
from pathlib import Path
p = Path('$manifest_file')
data = json.loads(p.read_text())
mirror = data.get('sourceos_mirror') or 'https://github.com/SourceOS-Linux/librewolf-source-mirror.git'
if mirror.startswith('git@github.com:'):
    mirror = 'https://github.com/' + mirror.split(':', 1)[1]
print(mirror)
PY
  else
    echo "https://github.com/SourceOS-Linux/librewolf-source-mirror.git"
  fi
}

mirror="${SOURCEOS_LIBREWOLF_MIRROR_DST:-$(mirror_from_manifest)}"

usage() {
  cat <<USAGE
Usage: $0 [--profile human-secure|agent-runtime] [--ref latest|tag|sha|branch] [--workspace-root DIR] [--dry-run]

Creates a BearBrowser build workspace from the clean upstream mirror, then applies SourceOS/BearBrowser overlays.

Options:
  --profile         Settings profile to inject. Default: agent-runtime.
  --ref             Upstream mirror ref to check out. Default: latest.
  --workspace-root  Generated workspace root. Default: build/workspaces.
  --dry-run         Print planned operations without modifying build output.
  -h, --help        Show this help.
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
    --workspace-root)
      workspace_root="${2:?missing workspace root}"
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
    echo "ERROR: invalid profile '$profile'. Expected human-secure or agent-runtime." >&2
    exit 1
    ;;
esac

profile_dir="$repo_root/settings/profiles/${profile}"
if [ ! -d "$profile_dir" ]; then
  echo "ERROR: missing profile directory: $profile_dir" >&2
  exit 1
fi

latest_tag() {
  git ls-remote --tags "$mirror" \
    | awk -F/ '{print $NF}' \
    | grep -E '^[0-9]+(\.[0-9]+)*-[0-9]+$' \
    | sort -V \
    | tail -1
}

resolved_ref="$ref"
if [ "$ref" = "latest" ]; then
  resolved_ref="$(latest_tag)"
fi

if [ -z "$resolved_ref" ]; then
  echo "ERROR: could not resolve upstream ref" >&2
  exit 1
fi

safe_ref="$(printf '%s' "$resolved_ref" | tr '/:@' '---')"
workspace="$repo_root/${workspace_root}/${profile}-${safe_ref}"
manifest="$workspace/bearbrowser-overlay-manifest.json"

echo "BearBrowser overlay plan"
echo "repo_root=$repo_root"
echo "mirror=$mirror"
echo "profile=$profile"
echo "requested_ref=$ref"
echo "resolved_ref=$resolved_ref"
echo "workspace=$workspace"
echo "dry_run=$dry_run"

if [ "$dry_run" = "true" ]; then
  echo "Dry run complete."
  exit 0
fi

rm -rf "$workspace"
mkdir -p "$(dirname "$workspace")"

git clone "$mirror" "$workspace/source"
git -C "$workspace/source" checkout "$resolved_ref"

patch_count=0
if compgen -G "$repo_root/patches/*.patch" >/dev/null; then
  for patch in "$repo_root"/patches/*.patch; do
    echo "Applying patch: $patch"
    git -C "$workspace/source" apply "$patch"
    patch_count=$((patch_count + 1))
  done
fi

bash "$repo_root/scripts/apply-bearbrowser-branding.sh" --workspace "$workspace/source"

mkdir -p "$workspace/overlay/settings"
cp -R "$profile_dir/." "$workspace/overlay/settings/"

cat > "$manifest" <<EOF_MANIFEST
{
  "product": "BearBrowser",
  "mode": "$profile",
  "mirror": "$mirror",
  "requestedRef": "$ref",
  "resolvedRef": "$resolved_ref",
  "patchCount": $patch_count,
  "branding": "BearBrowser",
  "brandingOverlay": "scripts/apply-bearbrowser-branding.sh",
  "sourceDir": "$workspace/source",
  "settingsDir": "$workspace/overlay/settings",
  "policyContract": "policy/bearbrowser-contract.yaml",
  "mountPlan": "mounts/agent-browser-mounts.yaml"
}
EOF_MANIFEST

echo "Overlay workspace created: $workspace"
echo "Manifest: $manifest"
