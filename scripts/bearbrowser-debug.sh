#!/usr/bin/env bash
# bearbrowser-debug.sh — launch BearBrowser with EVERYTHING captured, and if it
# dies without saying anything, DIAGNOSE it instead of printing an empty log.
#
#   bash scripts/bearbrowser-debug.sh              # your normal profile
#   bash scripts/bearbrowser-debug.sh --clean      # throwaway profile (hardened)
#
# Why: the shipped build was compiled with --disable-crashreporter, so a native
# crash leaves NO .ips, NO minidump, no Console entry. stderr is the only
# evidence, and launching from the Dock discards it.
set -uo pipefail

APP="${BEARBROWSER_APP:-/Applications/BearBrowser.app}"
BIN="$APP/Contents/MacOS/bearbrowser"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -x "$BIN" ] || { echo "not found: $BIN" >&2; exit 1; }

# A running instance makes -no-remote exit 0 INSTANTLY with zero output. Clear it.
if pgrep -f "BearBrowser.app/Contents/MacOS/bearbrowser" >/dev/null 2>&1; then
  echo "quitting running BearBrowser (it would make this run exit silently)…"
  pkill -f "BearBrowser.app/Contents/MacOS/bearbrowser"; sleep 2
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BEARBROWSER_DEBUG_DIR:-$HOME/bearbrowser-debug}"
mkdir -p "$OUT"
LOG="$OUT/bearbrowser-$STAMP.log"

ARGS=(-no-remote)
PROFILE=""
if [ "${1:-}" = "--clean" ]; then
  shift
  PROFILE="$OUT/profile-$STAMP"; mkdir -p "$PROFILE"
  [ -f "$REPO/settings/profiles/human-secure/user.js" ] &&
    cp "$REPO/settings/profiles/human-secure/user.js" "$PROFILE/user.js"
  ARGS+=(-profile "$PROFILE")
  echo "clean profile: $PROFILE"
fi

export MOZ_LOG="${MOZ_LOG:-nsHttp:3}"
export MOZ_LOG_FILE="$OUT/gecko-$STAMP"
export MOZ_CRASHREPORTER_SHUTDOWN=1
export XPCOM_DEBUG_BREAK=warn
export RUST_BACKTRACE=1

echo "log: $LOG"
echo "launching — reproduce the crash, then come back here."
START=$(date +%s)
"$BIN" "${ARGS[@]}" "$@" >"$LOG" 2>&1
CODE=$?
ELAPSED=$(( $(date +%s) - START ))
BYTES=$(wc -c <"$LOG" | tr -d ' ')

echo
echo "=== exited (code $CODE) after ${ELAPSED}s, ${BYTES} bytes of output ==="

# THE case that used to print nothing: instant, silent, "successful" exit.
if [ "$CODE" -eq 0 ] && [ "$BYTES" -eq 0 ] && [ "$ELAPSED" -lt 10 ]; then
  echo
  echo "🔴 SILENT INSTANT EXIT — the browser quit immediately, printed nothing, and"
  echo "   reported success. That is NOT a crash: it means profile selection was"
  echo "   wedged before any code ran. Diagnosing now:"
  echo
  bash "$REPO/scripts/bearbrowser-profile-doctor.sh" || true
  echo
  echo "Fastest confirmation — this bypasses the profile entirely:"
  echo "  bash scripts/bearbrowser-debug.sh --clean"
  exit 0
fi

echo "--- last 40 lines ---"; tail -40 "$LOG"
echo
echo "--- fatal signatures ---"
grep -nE "MOZ_CRASH|Assertion|###!!!|Segmentation|abort|Fatal|panicked|Hit MOZ|Exiting due to channel" "$LOG" | tail -20 ||
  echo "(none)"

# Local minidumps (present once the build ships --enable-crashreporter).
for d in "$PROFILE" "$HOME/Library/Application Support/BearBrowser/Profiles"/*; do
  [ -d "$d/crashes" ] || continue
  n=$(find "$d/crashes" -name '*.dmp' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] && echo "minidumps: $n in $d/crashes  (also see about:crashes)"
done
echo
echo "full log: $LOG"
