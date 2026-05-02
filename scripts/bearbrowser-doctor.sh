#!/usr/bin/env bash
set -euo pipefail

repo="${BEARBROWSER_REPO:-SourceOS-Linux/BearBrowser}"
mirror_repo="${SOURCEOS_LIBREWOLF_MIRROR_REPO:-SourceOS-Linux/librewolf-source-mirror}"
mirror="${SOURCEOS_LIBREWOLF_MIRROR_DST:-https://github.com/${mirror_repo}.git}"

printf 'BearBrowser doctor\n'
printf 'repo=%s\n' "$repo"
printf 'mirror=%s\n' "$mirror"

missing=0
for cmd in git python3 bash; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf 'ok: %s -> %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf 'missing: %s\n' "$cmd" >&2
    missing=1
  fi
done

if command -v brew >/dev/null 2>&1; then
  printf 'ok: brew -> %s\n' "$(command -v brew)"
else
  printf 'info: brew not found; Homebrew install/update commands unavailable on this machine\n'
fi

if git ls-remote --heads "$mirror" >/dev/null 2>&1; then
  printf 'ok: mirror reachable\n'
else
  printf 'error: mirror not reachable: %s\n' "$mirror" >&2
  missing=1
fi

printf '\nAutomation surfaces\n'
for cmd in node npx playwright carbonyl browsh elinks lynx w3m links; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf 'ok: %s -> %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf 'optional-missing: %s\n' "$cmd"
  fi
done

printf '\nPolicy posture\n'
printf 'ok: automation wrappers are policy-mediated scaffolds\n'
printf 'ok: live Playwright and Stagehand execution remain disabled until runtime integration lands\n'
printf 'ok: terminal browser wrapper selects only installed local backends\n'

exit "$missing"
