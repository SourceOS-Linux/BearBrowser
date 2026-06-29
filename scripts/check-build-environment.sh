#!/usr/bin/env bash
set -euo pipefail

os="$(uname -s)"
missing=0

required_common=(git python3 bash)
recommended_common=(node npm jq yq)
linux_tools=(gcc g++ make pkg-config tar gzip)
mac_tools=(xcrun clang make hdiutil codesign spctl)

check_cmd() {
  local cmd="$1"
  local required="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "ok: $cmd -> $(command -v "$cmd")"
  else
    if [ "$required" = "required" ]; then
      echo "missing: $cmd" >&2
      missing=1
    else
      echo "optional-missing: $cmd"
    fi
  fi
}

echo "BearBrowser build environment check"
echo "os=$os"

for cmd in "${required_common[@]}"; do
  check_cmd "$cmd" required
done

for cmd in "${recommended_common[@]}"; do
  check_cmd "$cmd" optional
done

case "$os" in
  Linux)
    echo
    echo "Linux build tools"
    for cmd in "${linux_tools[@]}"; do
      check_cmd "$cmd" optional
    done
    ;;
  Darwin)
    echo
    echo "macOS build tools"
    for cmd in "${mac_tools[@]}"; do
      check_cmd "$cmd" optional
    done
    ;;
  *)
    echo "info: unknown build host OS: $os"
    ;;
esac

echo
if [ "$missing" -eq 0 ]; then
  echo "BearBrowser build environment baseline check passed"
else
  echo "BearBrowser build environment baseline check failed" >&2
fi

exit "$missing"
