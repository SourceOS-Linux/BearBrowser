#!/usr/bin/env bash
set -euo pipefail

workspace=""
dry_run="false"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon="$repo_root/branding/bearbrowser.svg"

usage() {
  cat <<'USAGE'
Usage: apply-bearbrowser-branding --workspace PATH [--dry-run]

Applies BearBrowser product branding to a generated upstream-derived source workspace.

This script changes product-facing application names, desktop metadata, appstream metadata,
profile/branding strings, and icon assets. It intentionally avoids license and upstream
provenance files.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)
      workspace="${2:?missing workspace path}"
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

if [ -z "$workspace" ]; then
  echo "ERROR: --workspace is required" >&2
  usage >&2
  exit 1
fi

if [ ! -d "$workspace" ]; then
  echo "ERROR: workspace does not exist: $workspace" >&2
  exit 1
fi

if [ ! -f "$icon" ]; then
  echo "ERROR: BearBrowser icon missing: $icon" >&2
  exit 1
fi

changed=0

echo "BearBrowser branding overlay"
echo "workspace=$workspace"
echo "dry_run=$dry_run"

should_skip() {
  case "$1" in
    */.git/*|*/.bearbrowser/*|*/LICENSE*|*/COPYING*|*/README*|*/docs/*|*/doc/*|*/manifests/upstream.json)
      return 0
      ;;
  esac
  return 1
}

replace_text_file() {
  local file_path="$1"
  if should_skip "$file_path"; then
    return 0
  fi

  if ! file "$file_path" | grep -Eqi 'text|json|xml|html|desktop|ini|script|source|yaml|toml|makefile'; then
    return 0
  fi

  if ! grep -Iq . "$file_path"; then
    return 0
  fi

  if grep -Eqi 'LibreWolf|librewolf|Libre Wolf' "$file_path"; then
    echo "branding-text: $file_path"
    changed=$((changed + 1))
    if [ "$dry_run" != "true" ]; then
      python3 - "$file_path" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text(errors='ignore')
replacements = {
    'LibreWolf Browser': 'BearBrowser',
    'LibreWolf Web Browser': 'BearBrowser',
    'LibreWolf': 'BearBrowser',
    'Libre Wolf': 'BearBrowser',
    'librewolf': 'bearbrowser',
    'LibreWolf.desktop': 'BearBrowser.desktop',
    'io.gitlab.librewolf-community.librewolf': 'dev.sourceos.BearBrowser',
    'io.gitlab.librewolf-community': 'dev.sourceos.BearBrowser',
}
for old, new in replacements.items():
    text = text.replace(old, new)
p.write_text(text)
PY
    fi
  fi
}

while IFS= read -r -d '' file_path; do
  replace_text_file "$file_path"
done < <(find "$workspace" -type f -print0)

# Common browser/app icon destinations. Copy our SVG where likely product icons exist.
icon_dirs_seen=0
while IFS= read -r -d '' icon_dir; do
  echo "branding-icon-dir: $icon_dir"
  changed=$((changed + 1))
  icon_dirs_seen=$((icon_dirs_seen + 1))
  if [ "$dry_run" != "true" ]; then
    cp "$icon" "$icon_dir/bearbrowser.svg"
    for candidate in "$icon_dir"/librewolf*.svg "$icon_dir"/LibreWolf*.svg; do
      [ -e "$candidate" ] || continue
      cp "$icon" "$candidate"
    done
  fi
  [ "$icon_dirs_seen" -ge 50 ] && break
done < <(find "$workspace" -type d \( -iname '*icon*' -o -iname '*branding*' -o -iname '*browser*' \) -print0)

# Ensure a BearBrowser app id marker exists for downstream package steps.
if [ "$dry_run" != "true" ]; then
  mkdir -p "$workspace/.bearbrowser"
  cat > "$workspace/.bearbrowser/branding.json" <<EOF
{
  "product": "BearBrowser",
  "appId": "dev.sourceos.BearBrowser",
  "profileName": "BearBrowser",
  "upstreamDerivative": "upstream-derived",
  "upstreamAttribution": "See manifests/upstream.json and license notices.",
  "licenseNotice": "Preserve upstream license and attribution notices."
}
EOF
fi

echo "branding_changes=$changed"
