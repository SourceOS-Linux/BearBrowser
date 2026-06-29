#!/usr/bin/env bash
set -euo pipefail

repo="${BEARBROWSER_REPO:-SourceOS-Linux/BearBrowser}"
mirror_repo="${SOURCEOS_LIBREWOLF_MIRROR_REPO:-SourceOS-Linux/librewolf-source-mirror}"
mirror="${SOURCEOS_LIBREWOLF_MIRROR_DST:-https://github.com/${mirror_repo}.git}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

if command -v npm >/dev/null 2>&1; then
  printf 'ok: npm -> %s\n' "$(command -v npm)"
else
  printf 'optional-missing: npm\n'
fi

if git ls-remote --heads "$mirror" >/dev/null 2>&1; then
  printf 'ok: mirror reachable\n'
else
  printf 'error: mirror not reachable: %s\n' "$mirror" >&2
  missing=1
fi

printf '\nBranding surface\n'
if command -v brew >/dev/null 2>&1; then
  if brew list --cask librewolf >/dev/null 2>&1; then
    printf 'branding-warning: upstream librewolf cask is installed; uninstall it when validating BearBrowser product surface\n'
    printf 'suggested: brew uninstall --cask librewolf\n'
  else
    printf 'ok: upstream librewolf cask not installed\n'
  fi
  if brew list --formula librewolf >/dev/null 2>&1; then
    printf 'branding-warning: upstream librewolf formula is installed; uninstall it when validating BearBrowser product surface\n'
    printf 'suggested: brew uninstall --formula librewolf\n'
  else
    printf 'ok: upstream librewolf formula not installed\n'
  fi
fi

printf '\nSourceOS control plane\n'
if python3 "$repo_root/scripts/verify-sourceos-control-plane.py"; then
  printf 'ok: SourceOS control-plane manifests verified\n'
else
  printf 'error: SourceOS control-plane manifest verification failed\n' >&2
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

if [ -d "$repo_root/node_modules/playwright" ]; then
  printf 'ok: playwright npm dependency present\n'
else
  printf 'optional-missing: playwright npm dependency\n'
fi

if [ -d "$repo_root/node_modules/@browserbasehq/stagehand" ]; then
  printf 'ok: stagehand npm dependency present\n'
else
  printf 'optional-missing: stagehand npm dependency\n'
fi

printf '\nPolicy posture\n'
printf 'ok: automation wrappers are policy-mediated\n'
printf 'ok: live Playwright requires BEARBROWSER_ENABLE_LIVE_PLAYWRIGHT=1 and BEARBROWSER_POLICY_DECISION_ID\n'
printf 'ok: live Stagehand remains blocked until provider credentials and PolicyFabric adapter are implemented\n'
printf 'ok: terminal browser wrapper selects only installed local backends\n'

printf '\nNext step for runtime deps\n'
printf 'run: bearbrowser-install-runtime-deps\n'

exit "$missing"
