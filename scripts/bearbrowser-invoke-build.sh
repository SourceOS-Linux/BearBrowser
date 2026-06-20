#!/usr/bin/env bash
set -euo pipefail

# Invokes the upstream Gecko/LibreWolf build inside a prepared BearBrowser overlay workspace.
# The workspace must already exist — run apply-sourceos-overlays.sh first.

workspace_source=""
profile="human-secure"
jobs="${BEARBROWSER_BUILD_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}"
artifact_out=""
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-invoke-build --workspace SOURCE_DIR [--profile human-secure|agent-runtime] [--jobs N] [--artifact-out DIR]

Invokes ./mach build inside a prepared BearBrowser overlay workspace.

Requirements:
  - apply-sourceos-overlays.sh must have already run against this workspace.
  - Firefox build dependencies must be installed (run ./mach bootstrap if needed).
  - MOZCONFIG must be unset or point to the workspace .mozconfig.

Options:
  --workspace     Path to the prepared source directory (contains mach or Makefile).
  --profile       BearBrowser profile name, used to locate overlay settings. Default: human-secure.
  --jobs          Parallel build jobs. Default: detected CPU count.
  --artifact-out  Directory to copy the finished build artifacts into. Optional.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace_source="${2:?missing workspace path}"
      shift 2
      ;;
    --profile)
      profile="${2:?missing profile}"
      shift 2
      ;;
    --jobs)
      jobs="${2:?missing jobs count}"
      shift 2
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

if [ -z "$workspace_source" ]; then
  echo "ERROR: --workspace is required" >&2
  usage >&2
  exit 1
fi

if [ ! -d "$workspace_source" ]; then
  echo "ERROR: workspace source directory not found: $workspace_source" >&2
  exit 1
fi

cd "$workspace_source"

echo "BearBrowser build invocation"
echo "workspace_source=$workspace_source"
echo "profile=$profile"
echo "jobs=$jobs"

# Verify BearBrowser branding was applied — branding.json must exist.
if [ ! -f ".bearbrowser/branding.json" ]; then
  echo "ERROR: .bearbrowser/branding.json missing — apply-bearbrowser-branding.sh must run first" >&2
  exit 1
fi

# Verify no LibreWolf product identity remains in browser-visible surfaces.
if grep -r --include="*.json" --include="*.desktop" --include="*.ini" -l "librewolf" browser/ browser/branding/ 2>/dev/null | grep -v '.bearbrowser' | grep -q .; then
  echo "ERROR: LibreWolf identity found in product surface after branding pass" >&2
  echo "Re-run scripts/apply-bearbrowser-branding.sh --workspace $workspace_source" >&2
  exit 1
fi

# Set up .mozconfig from the LibreWolf-provided template.
# LibreWolf's assets/mozconfig.new is their canonical build configuration.
if [ -f "assets/mozconfig.new" ] && [ ! -f ".mozconfig" ]; then
  echo "mozconfig: copying from assets/mozconfig.new"
  cp assets/mozconfig.new .mozconfig
elif [ ! -f ".mozconfig" ]; then
  echo "WARNING: no assets/mozconfig.new and no .mozconfig — using Firefox defaults"
fi

# Inject BearBrowser-specific MOZ_APP overrides into .mozconfig.
# These ensure the compiled binary carries BearBrowser identity.
cat >> .mozconfig <<'MOZCONFIG_APPENDS'

# BearBrowser product identity overlays
export MOZ_APP_NAME=bearbrowser
export MOZ_APP_DISPLAYNAME=BearBrowser
export MOZ_APP_VENDOR=SourceOS
export MOZ_APP_ID={bear-browser-sourceos}
MOZCONFIG_APPENDS

# Overlay the BearBrowser profile settings into the source tree.
profile_dir="$repo_root/settings/profiles/${profile}"
if [ -d "$profile_dir" ]; then
  echo "settings: overlaying $profile_dir"
  profile_dest="browser/app/profile"
  mkdir -p "$profile_dest"
  if [ -f "$profile_dir/user.js" ]; then
    # browser/app/profile/*.js is a default-pref file (pref()), not a user.js
    # (user_pref()). Convert so the prefs actually apply.
    python3 "$script_dir/userjs-to-autoconfig.py" \
      "$profile_dir/user.js" "$profile_dest/bearbrowser-${profile}.js" --profile "$profile"
    echo "settings: user.js -> $profile_dest/bearbrowser-${profile}.js (user_pref→pref)"
  fi
  if [ -f "$profile_dir/policies.json" ]; then
    mkdir -p "distribution"
    # Strip inline // comments — Firefox rejects a commented policies.json.
    python3 "$script_dir/strip-json-comments.py" "$profile_dir/policies.json" "distribution/policies.json"
    echo "settings: policies.json -> distribution/policies.json (comments stripped)"
  fi
else
  echo "WARNING: profile directory not found: $profile_dir"
fi

# Check for mach — the canonical Firefox build entry point.
if [ ! -f "mach" ]; then
  echo "ERROR: mach not found in workspace — is this a valid Firefox/LibreWolf source tree?" >&2
  exit 1
fi

echo
echo "Starting BearBrowser browser build (jobs=$jobs)"
echo "This will take 30–90 minutes on first build. Subsequent builds are incremental."
echo

MOZJOBS="$jobs" ./mach build

echo
echo "BearBrowser build completed."

# Emit build artifact location.
dist_dir="$(./mach python -c 'import buildconfig; print(buildconfig.topobjdir)' 2>/dev/null || echo "obj-$(uname -m)-unknown")"
if [ -d "$dist_dir/dist" ]; then
  echo "Artifacts: $dist_dir/dist"
  if [ -n "$artifact_out" ]; then
    mkdir -p "$artifact_out"
    cp -R "$dist_dir/dist/." "$artifact_out/"
    echo "Artifacts copied to: $artifact_out"
  fi
else
  echo "dist dir not found at $dist_dir/dist — check build output above"
fi
