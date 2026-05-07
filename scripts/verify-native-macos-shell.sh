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
grep -q 'BBEmitEvent(@"memory.candidate_created"' "$source"
grep -q 'BBEmitEvent(@"automation.observed"' "$source"
grep -q 'BBProposeAction(@"share_page_with_agent"' "$source"
grep -q 'BBProposeAction(@"write_memory_candidate"' "$source"
grep -q 'Summarize Page' "$source"
grep -q 'summarizePage:' "$source"
grep -q 'evaluateJavaScript' "$source"
grep -q 'document.body.innerText' "$source"
grep -q 'bearbrowser-page-summary create --text-file' "$source"
grep -q 'Propose Share' "$source"
grep -q 'Memory Candidate' "$source"
grep -q 'Resolve Held' "$source"
grep -q 'Sidecar Status' "$source"
grep -q 'runCommandAndCaptureOutput' "$source"
grep -q 'bearbrowser-sidecar-open --print-url' "$source"
grep -q 'http://127.0.0.1:' "$source"
grep -q 'bearbrowser-resolve-action --latest-held --decision allow' "$source"
grep -q 'bearbrowser-resolve-action --latest-held --decision deny' "$source"
grep -q 'bearbrowser-memory-candidate resolve --latest-candidate --decision commit' "$source"
grep -q 'bearbrowser-memory-candidate resolve --latest-candidate --decision reject' "$source"
grep -q 'BBMemoryLooksSensitive' "$source"
grep -q '<REDACTED-SENSITIVE-MEMORY-CANDIDATE>' "$source"
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
