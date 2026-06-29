#!/usr/bin/env bash
set -euo pipefail

workspace="${1:-}"
if [ -z "$workspace" ]; then
  echo "Usage: discover-upstream-build-system WORKSPACE_SOURCE_DIR" >&2
  exit 1
fi

if [ ! -d "$workspace" ]; then
  echo "ERROR: workspace source directory not found: $workspace" >&2
  exit 1
fi

cd "$workspace"

echo "BearBrowser upstream build-system discovery"
echo "workspace=$workspace"

found=0
for path in mach Makefile assets/mozconfig.new scripts/bootstrap.py scripts/fetch-build.sh scripts/librewolf-patches.py; do
  if [ -e "$path" ]; then
    echo "found: $path"
    found=$((found + 1))
  fi
done

if [ -f mach ]; then
  echo "candidate-build-command: ./mach build"
fi

if [ -f Makefile ]; then
  echo "candidate-build-command: make"
fi

if [ -f assets/mozconfig.new ]; then
  echo "candidate-config: assets/mozconfig.new"
fi

if [ "$found" -eq 0 ]; then
  echo "ERROR: no recognizable upstream build-system markers found" >&2
  exit 1
fi

# Record build-system markers for release/debug metadata.
mkdir -p .bearbrowser
{
  echo "workspace=$workspace"
  echo "markers=$found"
  find . -maxdepth 3 \( -name mach -o -name Makefile -o -name mozconfig.new -o -name 'fetch-build.sh' -o -name 'librewolf-patches.py' \) -print | sort
} > .bearbrowser/build-system-discovery.txt

echo "Build-system discovery written: $workspace/.bearbrowser/build-system-discovery.txt"
