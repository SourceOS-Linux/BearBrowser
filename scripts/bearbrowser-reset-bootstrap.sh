#!/usr/bin/env bash
set -euo pipefail

profile="$HOME/Library/Application Support/BearBrowser/profile"
log="$HOME/Library/Logs/BearBrowser/launcher.log"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-reset-bootstrap [--kill-old-firefox] [--clear-profile] [--clear-log]

Resets BearBrowser bootstrap state.

Default behavior:
  - kills old Firefox processes that were launched with the BearBrowser bootstrap profile
  - keeps the BearBrowser profile and log

Options:
  --kill-old-firefox   Kill Firefox processes using the BearBrowser bootstrap profile. Default.
  --clear-profile      Remove the BearBrowser bootstrap profile.
  --clear-log          Truncate the BearBrowser launcher log.
USAGE
}

kill_old_firefox=true
clear_profile=false
clear_log=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --kill-old-firefox)
      kill_old_firefox=true
      shift
      ;;
    --clear-profile)
      clear_profile=true
      shift
      ;;
    --clear-log)
      clear_log=true
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

if [ "$kill_old_firefox" = "true" ]; then
  echo "Stopping old Firefox bootstrap processes using BearBrowser profile..."
  pids="$(pgrep -f "Application Support/BearBrowser/profile" || true)"
  if [ -n "$pids" ]; then
    printf '%s\n' "$pids" | xargs kill 2>/dev/null || true
    sleep 1
    pids2="$(pgrep -f "Application Support/BearBrowser/profile" || true)"
    if [ -n "$pids2" ]; then
      printf '%s\n' "$pids2" | xargs kill -9 2>/dev/null || true
    fi
    echo "ok: stopped old BearBrowser-profile Firefox processes"
  else
    echo "ok: no old BearBrowser-profile Firefox processes found"
  fi
fi

if [ "$clear_profile" = "true" ]; then
  rm -rf "$profile"
  echo "ok: removed BearBrowser bootstrap profile: $profile"
fi

if [ "$clear_log" = "true" ]; then
  mkdir -p "$(dirname "$log")"
  : > "$log"
  echo "ok: cleared BearBrowser launcher log: $log"
fi

echo "BearBrowser bootstrap reset complete"
