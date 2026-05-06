#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source="native/macos/BearBrowserWebKitLauncher.m"
landing="native/macos/BearBrowser-start.html"

test -f "$source"
test -f "$landing"

grep -q 'BBEmitEvent(@"app.launch"' "$source"
grep -q 'BBEmitEvent(@"navigation.requested"' "$source"
grep -q 'BBEmitEvent(@"navigation.committed"' "$source"
grep -q 'BBProposeAction(@"share_page_with_agent"' "$source"
grep -q 'Sidecar Status' "$source"
grep -q 'BearBrowser native bootstrap active' "$landing"

if [ "$(uname -s)" = "Darwin" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  clang -fobjc-arc -framework Cocoa -framework WebKit "$source" -o "$tmp/BearBrowser"
  test -x "$tmp/BearBrowser"
  echo "ok: native macOS shell compiles"
else
  echo "info: non-Darwin host; skipped native compile"
fi

echo "BearBrowser native macOS shell verified"
