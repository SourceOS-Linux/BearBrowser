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
  human-secure|agent-runtime|tor-mode) ;;
  *)
    echo "ERROR: invalid profile '$profile'. Expected human-secure, agent-runtime, or tor-mode." >&2
    exit 1
    ;;
esac

# Tor mode must ride the SAME Firefox major as the Tor Browser cohort, so the
# RFP-frozen UA reads Firefox/<major>.0 identically. Tor Browser 15.x rides
# Firefox 140 ESR; RFP freezes the UA to "140.0" regardless of point release, so
# any 140-line mirror tag (e.g. 140.0.4-1) is fingerprint-equivalent at the UA
# layer. Building tor-mode on the latest overall tag (150) would emit
# Firefox/150.0 and split us into a distinct cohort. See docs/tor-mode.md §version.
tor_cohort_major="${BEARBROWSER_TOR_COHORT_MAJOR:-140}"

profile_dir="$repo_root/settings/profiles/${profile}"
if [ ! -d "$profile_dir" ]; then
  echo "ERROR: missing profile directory: $profile_dir" >&2
  exit 1
fi

# latest_tag [major]: newest mirror tag, optionally constrained to a Firefox major
# (e.g. latest_tag 140 -> latest 140.x.y-N tag, for Tor-cohort alignment).
latest_tag() {
  local major="${1:-}"
  local filter='^[0-9]+(\.[0-9]+)*-[0-9]+$'
  [ -n "$major" ] && filter="^${major}(\\.[0-9]+)*-[0-9]+$"
  git ls-remote --tags "$mirror" \
    | awk -F/ '{print $NF}' \
    | grep -E "$filter" \
    | sort -V \
    | tail -1
}

resolved_ref="$ref"
if [ "$ref" = "latest" ]; then
  if [ "$profile" = "tor-mode" ]; then
    resolved_ref="$(latest_tag "$tor_cohort_major")"
    if [ -z "$resolved_ref" ]; then
      echo "ERROR: tor-mode requires a Firefox $tor_cohort_major-line tag in the mirror (Tor cohort alignment), but none was found." >&2
      exit 1
    fi
    echo "tor-mode: pinned to Firefox ${tor_cohort_major} cohort -> $resolved_ref"
  else
    resolved_ref="$(latest_tag)"
  fi
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

# Tor mode: retarget the Firefox SOURCE to the current ESR point release.
# The mirror tag (140.0.4-1) supplies LibreWolf's BUILD SCRIPTS; its `version`
# file pins the 140.0.4 *release* tarball, which is ~a year of security backports
# behind the 140.x ESR that Tor Browser actually ships. The LibreWolf Makefile
# fetches `archive.mozilla.org/.../releases/$(version)/source/firefox-$(version)
# .source.tar.xz`, which is version-string-driven — Mozilla hosts the ESR source
# at the SAME path — so overriding the `version` file to an esr string pulls the
# current-security ESR source with no Makefile change. RFP still freezes the UA
# to "140.0", so the Tor-cohort match is preserved AND we get current security.
# NOTE: LibreWolf's 140.0.4-era patch stack must be verified against the ESR tree
# (run check-patchfail.sh on the ESR source) — same major, but ESR backports can
# shift hunks. Override the version with BEARBROWSER_TOR_FIREFOX_VERSION, or set
# it empty to keep the mirror's release pin (140.0.4) as a fallback.
if [ "$profile" = "tor-mode" ]; then
  tor_ff_version="${BEARBROWSER_TOR_FIREFOX_VERSION-140.12.0esr}"
  if [ -n "$tor_ff_version" ]; then
    echo "tor-mode: retargeting Firefox source -> $tor_ff_version (was $(cat "$workspace/source/version" 2>/dev/null))"
    printf '%s\n' "$tor_ff_version" > "$workspace/source/version"
  fi
fi

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
#
# Tor mode OMITS them. By the spoof-normality decision (docs/tor-mode.md), Tor
# mode disables CanvasTextMetrics + WebAudioFarble to match the Tor Browser cohort
# (which quantizes neither) — so compiling them in only to disable them via the
# overrides pref is pointless. Omitting is behaviorally identical AND avoids
# rebasing these 150-authored patches onto the 140 ESR tree (their hunks reject on
# 140; the LibreWolf stack itself applies cleanly — proven in CI).
afp_dir="$repo_root/gecko-patches/anti-fingerprint"
patches_txt="$workspace/source/assets/patches.txt"
if [ "$profile" = "tor-mode" ]; then
  echo "feature-layer: tor-mode omits bearbrowser anti-fp patches (disabled to match cohort; see docs/tor-mode.md)"
elif [ -d "$afp_dir" ] && [ -f "$patches_txt" ]; then
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
