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

# ---------------------------------------------------------------------------
# Install the BearBrowser feature layer into the upstream workspace.
#
# This repo is the overlay; the cloned mirror is the LibreWolf/Firefox base.
# The branding step rewrites the upstream Makefile to invoke
# scripts/bearbrowser-patches.py, and THIS repo carries the canonical copy of
# that script (the mirror only tracks scripts/librewolf-patches.py). The patch
# script in turn copies the BearBrowser actors / BearBlocker / filter-list
# sources from settings/, which also live HERE, not in the mirror. Without this
# step `make dir` either can't find the patch script or silently skips every
# BearBrowser feature, shipping a branded-but-vanilla Firefox.
# ---------------------------------------------------------------------------
cp "$repo_root/scripts/bearbrowser-patches.py" "$workspace/source/scripts/bearbrowser-patches.py"
echo "feature-layer: installed canonical bearbrowser-patches.py"

for asset in actors bearblocker filter-lists extensions; do
  if [ -d "$repo_root/settings/$asset" ]; then
    mkdir -p "$workspace/source/settings/$asset"
    cp -R "$repo_root/settings/$asset/." "$workspace/source/settings/$asset/"
    echo "feature-layer: overlaid settings/$asset"
  fi
done

# Anti-fingerprint Gecko patches. These live in THIS overlay (gecko-patches/),
# never in the read-only librewolf mirror — they are copied into the transient
# workspace clone and registered in the upstream patch list so bearbrowser-
# patches.py applies them (patch -p1) to the extracted Firefox source during the
# build. Order matters: canvas before audio (both edit RFPTargets.inc, verified
# to apply in sequence).
afp_dir="$repo_root/gecko-patches/anti-fingerprint"
patches_txt="$workspace/source/assets/patches.txt"
if [ -d "$afp_dir" ] && [ -f "$patches_txt" ]; then
  mkdir -p "$workspace/source/patches"
  for p in anti-fp-canvas-text-metrics.patch anti-fp-audio.patch; do
    if [ -f "$afp_dir/$p" ]; then
      cp "$afp_dir/$p" "$workspace/source/patches/$p"
      grep -qxF "patches/$p" "$patches_txt" || echo "patches/$p" >> "$patches_txt"
      echo "feature-layer: registered anti-fp patch $p"
    fi
  done
fi

mkdir -p "$workspace/overlay/settings"
cp -R "$profile_dir/." "$workspace/overlay/settings/"

# policies.json is documented with inline // comments in source, but Firefox's
# enterprise policy engine parses it as strict JSON and silently rejects the
# whole file if any comment is present. Strip comments on the way into the
# overlay so the deployed file is valid strict JSON.
if [ -f "$workspace/overlay/settings/policies.json" ]; then
  python3 "$script_dir/strip-json-comments.py" "$workspace/overlay/settings/policies.json"
  echo "settings: stripped JSONC comments from overlay policies.json"
fi

# ---------------------------------------------------------------------------
# Generate the profile's REAL settings into the upstream settings tree.
#
# `make dir` runs scripts/bearbrowser-patches.py, which compiles the browser's
# settings from <source>/settings/ (see the lw/ packaging block):
#   settings/distribution/policies.json   -> dist .../distribution/policies.json
#   settings/bearbrowser.cfg              -> autoconfig (general.config.filename)
#   settings/defaults/pref/local-settings.js -> wires general.config.* to the .cfg
# These are generated here from the profile so the build is self-contained and
# does not depend on the mirror's (empty placeholder / unpopulated submodule)
# settings. Without this the build shipped with none of BearBrowser's policy or
# pref hardening — just a branded vanilla Firefox.
#   - policies.json: comment-stripped to strict JSON (Firefox rejects comments).
#   - bearbrowser.cfg: generated from user.js (user_pref -> pref).
#   - local-settings.js: the fixed autoconfig wiring (points at bearbrowser.cfg).
# ---------------------------------------------------------------------------
inject_dist="$workspace/source/settings/distribution"
inject_pref="$workspace/source/settings/defaults/pref"
mkdir -p "$inject_dist" "$inject_pref"

if [ -f "$profile_dir/policies.json" ]; then
  python3 "$script_dir/strip-json-comments.py" \
    "$profile_dir/policies.json" "$inject_dist/policies.json"
  echo "settings: injected $profile policies.json -> source/settings/distribution/policies.json"
fi

if [ -f "$profile_dir/user.js" ]; then
  python3 "$script_dir/userjs-to-autoconfig.py" \
    "$profile_dir/user.js" "$workspace/source/settings/bearbrowser.cfg" \
    --profile "$profile"
  echo "settings: injected $profile user.js -> source/settings/bearbrowser.cfg (autoconfig)"
fi

# The autoconfig wiring: tell Firefox to load bearbrowser.cfg as the lockable
# config file. obscure_value 0 means the .cfg is plain text (not byte-shifted).
cat > "$inject_pref/local-settings.js" <<'EOF_LOCALSETTINGS'
// BearBrowser autoconfig wiring — generated by apply-sourceos-overlays.sh
pref("general.config.obscure_value", 0);
pref("general.config.filename", "bearbrowser.cfg");
EOF_LOCALSETTINGS
echo "settings: wrote autoconfig wiring -> source/settings/defaults/pref/local-settings.js"

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
  "injectedSettingsDir": "$workspace/source/settings",
  "policyContract": "policy/bearbrowser-contract.yaml",
  "mountPlan": "mounts/agent-browser-mounts.yaml"
}
EOF_MANIFEST

echo "Overlay workspace created: $workspace"
echo "Manifest: $manifest"
