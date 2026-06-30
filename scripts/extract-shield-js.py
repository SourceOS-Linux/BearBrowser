#!/usr/bin/env python3
"""
Extract the JS fingerprinting shield from BearBrowserWebKitLauncher.m.

Parses the NSString *shield = @"..." concatenation and emits the raw JS
to stdout. Used by verify-fingerprint-shield.mjs to inject the shield into
a headless WebKit browser for automated regression testing.

Usage:
    python3 scripts/extract-shield-js.py > build/shield.js
    python3 scripts/extract-shield-js.py  # stdout
"""
import re
import sys
from pathlib import Path

repo_root = Path(__file__).parent.parent
launcher = repo_root / "native" / "macos" / "BearBrowserWebKitLauncher.m"

if not launcher.exists():
    sys.stderr.write(f"error: {launcher} not found\n")
    sys.exit(1)

content = launcher.read_text()

# Find the block from `NSString *shield=` to the first `WKUserScript *shieldScript`
m = re.search(
    r'NSString \*shield\s*=\s*((?:.*?\n)*?)\s*WKUserScript \*shieldScript',
    content,
    re.DOTALL,
)
if not m:
    sys.stderr.write("error: could not locate shield NSString block\n")
    sys.exit(1)

block = m.group(1)

# Extract ObjC string literal contents: @"..." — handle escaped chars
# ObjC string literals: @"content" where content may contain \" and \\
literals = re.findall(r'@"((?:[^"\\]|\\.)*)"', block)

js = "".join(literals)

# Unescape ObjC escape sequences → real characters
js = js.replace('\\"', '"')
js = js.replace('\\\\', '\\')
js = js.replace('\\n', '\n')
js = js.replace('\\t', '\t')

sys.stdout.write(js)
