#!/usr/bin/env bash
set -euo pipefail

url="about:blank"
dry_run="false"
preferred="auto"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-terminal [--browser auto|carbonyl|browsh|elinks|lynx|w3m|links] [--url URL] [--dry-run]

Selects the best available terminal browser backend for BearBrowser-compatible
terminal browsing.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --browser)
      preferred="${2:?missing browser}"
      shift 2
      ;;
    --url)
      url="${2:?missing url}"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
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

candidates=()
case "$preferred" in
  auto)
    candidates=(carbonyl browsh elinks w3m links lynx)
    ;;
  carbonyl|browsh|elinks|lynx|w3m|links)
    candidates=("$preferred")
    ;;
  *)
    echo "ERROR: unsupported terminal browser: $preferred" >&2
    exit 1
    ;;
esac

selected=""
for candidate in "${candidates[@]}"; do
  if command -v "$candidate" >/dev/null 2>&1; then
    selected="$candidate"
    break
  fi
done

cat <<EOF
BearBrowser terminal adapter
preferred=$preferred
selected=${selected:-none}
url=$url
policy=PolicyFabric
provenance=required-for-agent-runtime
EOF

if [ "$dry_run" = "true" ]; then
  if [ -n "$selected" ]; then
    echo "Dry run complete. Terminal browser launch would use: $selected"
  else
    echo "optional-missing: no supported terminal browser found"
    echo "Install one of: carbonyl, browsh, elinks, w3m, links, lynx"
    echo "Dry run complete."
  fi
  exit 0
fi

if [ -z "$selected" ]; then
  echo "missing: no supported terminal browser found"
  echo "Install one of: carbonyl, browsh, elinks, w3m, links, lynx"
  exit 2
fi

case "$selected" in
  carbonyl|browsh|elinks|lynx|w3m|links)
    exec "$selected" "$url"
    ;;
esac
