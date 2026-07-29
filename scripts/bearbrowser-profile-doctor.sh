#!/usr/bin/env bash
# bearbrowser-profile-doctor.sh — diagnose (and optionally repair) the profile
# state that makes BearBrowser exit INSTANTLY AND SILENTLY (exit 0, no output,
# no window, no crash log).
#
#   bash scripts/bearbrowser-profile-doctor.sh          # diagnose only
#   bash scripts/bearbrowser-profile-doctor.sh --fix    # repair (backs up first)
#
# Reproduced 2026-07-29: default profile -> exit 0 / 0 bytes; clean profile ->
# runs fine. Causes seen in the wild:
#   * multiple [InstallXXXX] sections in profiles.ini, each with its own
#     Default= — created when the app is launched from several PATHS (a mounted
#     DMG, /Applications, a copy). Firefox keys the default profile to an
#     install-path hash, so each path mints a new default-default-N profile.
#   * a stale .parentlock left by a previous hard crash.
# Either can leave profile selection wedged; with -no-remote the process just
# exits 0 without printing anything, which is impossible to debug blind.
set -uo pipefail

ROOT="${BEARBROWSER_PROFILE_ROOT:-$HOME/Library/Application Support/BearBrowser}"
INI="$ROOT/profiles.ini"
FIX=0; [ "${1:-}" = "--fix" ] && FIX=1

echo "profile root: $ROOT"
[ -f "$INI" ] || { echo "no profiles.ini — nothing to diagnose (a fresh profile will be created)"; exit 0; }

if pgrep -f "BearBrowser.app/Contents/MacOS/bearbrowser" >/dev/null 2>&1; then
  echo "⚠️  BearBrowser is RUNNING. Quit it first (locks are meaningless while it runs)."
  [ $FIX -eq 1 ] && { echo "refusing to --fix while running."; exit 1; }
fi

installs=$(grep -c '^\[Install' "$INI" 2>/dev/null || echo 0)
profiles=$(grep -c '^\[Profile' "$INI" 2>/dev/null || echo 0)
echo "profiles.ini: $profiles profile section(s), $installs install section(s)"
[ "$installs" -gt 1 ] && echo "  🔴 $installs [Install] sections — app was launched from multiple PATHS; each minted its own default profile. This is the wedge."
echo

echo "locks (stale = left by a crash, browser not running):"
found=0
while IFS= read -r lk; do
  found=1; echo "  $lk"
done < <(find "$ROOT/Profiles" \( -name '.parentlock' -o -name 'lock' \) 2>/dev/null)
[ $found -eq 0 ] && echo "  (none)"
echo

if [ $FIX -eq 0 ]; then
  echo "Diagnose only. To repair (backs up profiles.ini + moves nothing destructive):"
  echo "  bash scripts/bearbrowser-profile-doctor.sh --fix"
  echo
  echo "Immediate workaround that always works (uses a throwaway profile):"
  echo "  /Applications/BearBrowser.app/Contents/MacOS/bearbrowser -no-remote -profile /tmp/bb-clean"
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
cp "$INI" "$INI.bak-$STAMP" && echo "backed up profiles.ini -> $INI.bak-$STAMP"

# 1. Remove stale locks (safe: browser is not running, checked above).
n=0
while IFS= read -r lk; do rm -f "$lk" && n=$((n+1)); done \
  < <(find "$ROOT/Profiles" \( -name '.parentlock' -o -name 'lock' \) 2>/dev/null)
echo "removed $n stale lock file(s)"

# 2. Collapse the competing [Install] sections to ONE pointing at the newest
#    profile, so every launch path resolves to the same profile. Profiles
#    themselves are never deleted — only the ini's install mapping is rewritten.
python3 - "$INI" <<'PY'
import re,sys,os
p=sys.argv[1]; s=open(p).read()
blocks=re.split(r'(?m)^(?=\[)',s)
installs=[b for b in blocks if b.startswith('[Install')]
if len(installs)<=1:
    print("install sections: nothing to collapse"); raise SystemExit
# keep the Default= of the LAST install section (most recently used path)
last=installs[-1]
m=re.search(r'(?m)^Default=(.+)$',last)
keep=m.group(1).strip() if m else None
rest=[b for b in blocks if not b.startswith('[Install')]
if keep:
    rest.append(f"[Install01]\nDefault={keep}\nLocked=1\n")
open(p,'w').write(''.join(rest))
print(f"collapsed {len(installs)} install sections -> 1 (Default={keep})")
PY

echo
echo "✅ repaired. Launch normally; if it still exits instantly, run with a clean"
echo "   profile and tell Claude — that would mean a second, different cause."
