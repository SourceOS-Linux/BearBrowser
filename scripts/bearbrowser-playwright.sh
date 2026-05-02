#!/usr/bin/env bash
set -euo pipefail

mode="agent-runtime"
dry_run="false"
url="about:blank"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-playwright [--mode agent-runtime|human-secure] [--url URL] [--dry-run]

Policy-mediated Playwright control surface for BearBrowser.

This wrapper is intentionally conservative. It validates operator intent,
reports the policy/provenance envelope, and refuses to imply authority outside
PolicyFabric.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      mode="${2:?missing mode}"
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

case "$mode" in
  agent-runtime|human-secure) ;;
  *)
    echo "ERROR: invalid mode: $mode" >&2
    exit 1
    ;;
esac

cat <<EOF
BearBrowser Playwright adapter
mode=$mode
url=$url
policy=PolicyFabric
provenance=required-for-agent-runtime
authority=not-granted-by-wrapper
remoteDebuggingDefault=denied
EOF

if ! command -v node >/dev/null 2>&1; then
  echo "missing: node"
  echo "Install Node or use the BearBrowser Brewfile before enabling Playwright automation."
  exit 2
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "missing: npx"
  echo "Install npm/npx before enabling Playwright automation."
  exit 2
fi

if [ "$dry_run" = "true" ]; then
  echo "Dry run complete. Playwright launch would be policy-mediated."
  exit 0
fi

cat >&2 <<'EOF'
ERROR: live Playwright launch is not enabled yet.
Next step: wire this wrapper to a governed BrowserContext launcher that emits BearBrowser provenance events.
EOF
exit 64
