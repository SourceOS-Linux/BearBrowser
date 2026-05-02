#!/usr/bin/env bash
set -euo pipefail

repo="${SOURCEOS_LIBREWOLF_MIRROR_REPO:-SourceOS-Linux/librewolf-source-mirror}"
dst="${SOURCEOS_LIBREWOLF_MIRROR_DST:-git@github.com:${repo}.git}"

branches="$(git ls-remote --heads "$dst" | wc -l | tr -d ' ')"
tags="$(git ls-remote --tags "$dst" | wc -l | tr -d ' ')"
hidden="$(git ls-remote "$dst" 'refs/merge-requests/*' 'refs/pipelines/*' 'refs/pull/*' 'refs/notes/*' | wc -l | tr -d ' ')"
latest_tag="$(git ls-remote --tags "$dst" | awk -F/ '{print $NF}' | grep -E '^[0-9]+(\.[0-9]+)*-[0-9]+$' | sort -V | tail -1 || true)"

echo "mirror=$repo"
echo "branches=$branches"
echo "tags=$tags"
echo "hidden_refs=$hidden"
echo "latest_tag=${latest_tag:-unknown}"

if [ "$hidden" != "0" ]; then
  echo "ERROR: mirror contains noncanonical hidden refs" >&2
  exit 1
fi

if [ "$branches" -lt 1 ]; then
  echo "ERROR: mirror has no branches" >&2
  exit 1
fi

if [ "$tags" -lt 1 ]; then
  echo "ERROR: mirror has no tags" >&2
  exit 1
fi
