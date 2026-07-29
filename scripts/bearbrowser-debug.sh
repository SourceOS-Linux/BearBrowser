#!/usr/bin/env bash
# bearbrowser-debug.sh — launch BearBrowser with EVERYTHING captured.
#
# Why this exists: the build ships --disable-crashreporter, so a native crash
# leaves NO .ips, NO minidump, NO Console.app entry — the app just vanishes.
# The only surviving evidence is stderr, which is lost when you launch from the
# Dock. This wrapper captures it (plus Gecko's own logs) to a file that outlives
# the crash.
#
#   bash scripts/bearbrowser-debug.sh              # your normal profile
#   bash scripts/bearbrowser-debug.sh --clean      # throwaway profile
#
# Reproduce the crash, then read the tail it prints.
set -uo pipefail

APP="${BEARBROWSER_APP:-/Applications/BearBrowser.app}"
BIN="$APP/Contents/MacOS/bearbrowser"
[ -x "$BIN" ] || { echo "not found: $BIN" >&2; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${BEARBROWSER_DEBUG_DIR:-$HOME/bearbrowser-debug}"
mkdir -p "$OUT"
LOG="$OUT/bearbrowser-$STAMP.log"

ARGS=(-no-remote)
if [ "${1:-}" = "--clean" ]; then
  P="$OUT/profile-$STAMP"; mkdir -p "$P"
  # Carry our hardened prefs into the throwaway profile when available.
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  [ -f "$REPO/settings/profiles/human-secure/user.js" ] &&
    cp "$REPO/settings/profiles/human-secure/user.js" "$P/user.js"
  ARGS+=(-profile "$P")
  echo "clean profile: $P"
fi

# Gecko's own logging to a file, plus JS/XPConnect noise on stderr.
export MOZ_LOG="${MOZ_LOG:-nsHttp:3,DocShellLeak:5}"
export MOZ_LOG_FILE="$OUT/gecko-$STAMP"
export MOZ_CRASHREPORTER_SHUTDOWN=1
export XPCOM_DEBUG_BREAK=warn
export RUST_BACKTRACE=1

echo "log: $LOG"
echo "launching — reproduce the crash, then come back here."
"$BIN" "${ARGS[@]}" "$@" >"$LOG" 2>&1
CODE=$?

echo
echo "=== exited (code $CODE) ==="
echo "--- last 40 lines of $LOG ---"
tail -40 "$LOG"
echo
echo "--- fatal signatures found ---"
grep -nE "MOZ_CRASH|Assertion|###!!!|Segmentation|abort|Fatal|panicked|Hit MOZ|NS_ERROR_[A-Z_]+|Exiting due to channel" "$LOG" | tail -20 ||
  echo "(none — a silent exit means the parent quit cleanly; check the Gecko logs: $OUT/gecko-$STAMP*)"
echo
echo "full log: $LOG"
