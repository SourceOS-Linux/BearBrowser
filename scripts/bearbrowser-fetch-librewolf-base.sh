#!/usr/bin/env bash
# Fetches the LibreWolf macOS base binary via Homebrew cask.
# Homebrew handles download, checksum verification, and quarantine.
# Output: the path to the installed LibreWolf.app bundle.
set -euo pipefail

out_var="false"
force="false"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-fetch-librewolf-base [--print-path] [--force]

Ensures LibreWolf is installed via Homebrew cask (brew install --cask librewolf).
Homebrew verifies the download checksum. No manual URL handling.

Options:
  --print-path   Print the LibreWolf.app path and exit after ensuring it is installed.
  --force        Re-install even if already present.

Exit codes:
  0   LibreWolf.app is available at the printed path.
  1   Error fetching the base binary.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --print-path) out_var="true"; shift ;;
    --force)      force="true"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v brew >/dev/null 2>&1; then
  echo "ERROR: brew not found — Homebrew is required to fetch the LibreWolf base binary." >&2
  echo "Install Homebrew from https://brew.sh and re-run." >&2
  exit 1
fi

# Resolve the installed app path. Homebrew casks install apps into the Caskroom
# staging area, not /Applications — check Caskroom first, then /Applications fallback.
locate_installed_app() {
  local cask_dir
  cask_dir="$(brew --caskroom)/librewolf"
  if [ -d "$cask_dir" ]; then
    local found
    found="$(find "$cask_dir" -maxdepth 3 -name 'LibreWolf.app' -type d 2>/dev/null | sort -V | tail -1)"
    if [ -n "$found" ]; then
      echo "$found"
      return
    fi
  fi
  # Fallback: Homebrew may have linked to /Applications.
  if [ -d "/Applications/LibreWolf.app" ]; then
    echo "/Applications/LibreWolf.app"
  fi
}

# Check if already installed and not forcing.
if [ "$force" != "true" ]; then
  existing="$(locate_installed_app)"
  if [ -n "$existing" ] && [ -d "$existing" ]; then
    echo "LibreWolf base binary already present: $existing"
    if [ "$out_var" = "true" ]; then
      echo "$existing"
    fi
    exit 0
  fi
fi

echo "Fetching LibreWolf base binary via Homebrew..."
echo "(Homebrew verifies the download checksum — no manual URL handling needed.)"
echo

if [ "$force" = "true" ]; then
  brew reinstall --cask librewolf
else
  brew install --cask librewolf
fi

app_path="$(locate_installed_app)"
if [ -z "$app_path" ] || [ ! -d "$app_path" ]; then
  echo "ERROR: LibreWolf.app not found after Homebrew install." >&2
  echo "Check: brew --caskroom" >&2
  exit 1
fi

echo "LibreWolf base binary installed: $app_path"
if [ "$out_var" = "true" ]; then
  echo "$app_path"
fi
