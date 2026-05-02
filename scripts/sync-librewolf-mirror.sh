#!/usr/bin/env bash
set -euo pipefail

repo="${SOURCEOS_LIBREWOLF_MIRROR_REPO:-SourceOS-Linux/librewolf-source-mirror}"
src="${SOURCEOS_LIBREWOLF_UPSTREAM:-https://codeberg.org/librewolf/source.git}"
dst="${SOURCEOS_LIBREWOLF_MIRROR_DST:-git@github.com:${repo}.git}"
tmp="${SOURCEOS_LIBREWOLF_MIRROR_TMP:-/tmp/librewolf-source-mirror.git}"

if [ ! -d "$tmp" ]; then
  git clone --mirror "$src" "$tmp"
fi

cd "$tmp"
git remote set-url origin "$src"
git fetch --prune origin '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'

for ns in refs/merge-requests refs/pipelines refs/pull refs/notes; do
  git for-each-ref --format='%(refname)' "$ns" | while read -r ref; do
    git update-ref -d "$ref" || true
  done
done

delete_refs="$(git ls-remote "$dst" 'refs/merge-requests/*' 'refs/pipelines/*' 'refs/notes/*' | awk '{print ":"$2}')"
if [ -n "$delete_refs" ]; then
  printf '%s\n' "$delete_refs" | xargs -n 50 git push "$dst"
fi

git push --prune "$dst" '+refs/heads/*:refs/heads/*' '+refs/tags/*:refs/tags/*'
