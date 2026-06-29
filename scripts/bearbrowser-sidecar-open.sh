#!/usr/bin/env bash
set -euo pipefail

host="127.0.0.1"
port="8765"
open_url=false
print_url=false
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_dir="$HOME/Library/Logs/BearBrowser"
log="$log_dir/sidecar-server.log"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-sidecar-open [--port 8765] [--print-url] [--open]

Starts the BearBrowser localhost-only interactive sidecar server if needed and
prints or opens the tokenized local URL.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --port)
      port="${2:?missing port}"
      shift 2
      ;;
    --print-url)
      print_url=true
      shift
      ;;
    --open)
      open_url=true
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

mkdir -p "$log_dir"
url="$(python3 "$script_dir/bearbrowser-sidecar-server.py" --port "$port" --print-url)"

if ! python3 - "$url" <<'PY' >/dev/null 2>&1
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=0.8) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
then
  nohup python3 "$script_dir/bearbrowser-sidecar-server.py" --host "$host" --port "$port" >>"$log" 2>&1 &
  server_pid=$!
  ok=false
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if python3 - "$url" <<'PY' >/dev/null 2>&1
import sys, urllib.request
try:
    with urllib.request.urlopen(sys.argv[1], timeout=0.8) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
    then
      ok=true
      break
    fi
    sleep 0.2
  done
  if [ "$ok" != true ]; then
    echo "ERROR: BearBrowser sidecar server did not become ready. pid=$server_pid log=$log" >&2
    exit 1
  fi
fi

if [ "$open_url" = true ]; then
  if command -v open >/dev/null 2>&1; then
    open "$url"
  else
    echo "open command unavailable; URL: $url" >&2
  fi
fi

if [ "$print_url" = true ] || [ "$open_url" != true ]; then
  echo "$url"
fi
