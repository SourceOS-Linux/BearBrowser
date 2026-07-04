#!/usr/bin/env python3
"""Strip // line and /* */ block comments from a JSONC file, emit strict JSON.

Firefox's Enterprise Policy engine (and the distribution/policies.json reader)
parse policies.json with a strict JSON.parse — comments are NOT permitted. If a
commented file ships verbatim, Firefox silently rejects the ENTIRE policy file
and none of the policies apply. Our source policies.json files are deliberately
documented with inline comments, so the build must strip them on the way out.

This stripper is string-aware: it will not touch a "//" that appears inside a
JSON string value (e.g. "https://9.9.9.9/dns-query"). The output is validated
with json.loads before being written, so a malformed source fails the build
loudly instead of shipping a broken policy file.

Usage:
    strip-json-comments.py SRC DST     # write stripped strict JSON to DST
    strip-json-comments.py SRC         # strip in place (SRC overwritten)
    strip-json-comments.py --check SRC # validate only, write nothing
"""

import json
import sys


def strip_jsonc(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                # Preserve escaped char verbatim (covers \" and \\).
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        # Not in a string.
        if c == '"':
            in_string = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            # Line comment — skip to end of line (keep the newline).
            i += 2
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            # Block comment — skip to closing */.
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def main(argv):
    check_only = False
    args = []
    for a in argv[1:]:
        if a == "--check":
            check_only = True
        else:
            args.append(a)

    if not args:
        sys.stderr.write(__doc__)
        return 2

    src = args[0]
    dst = args[1] if len(args) > 1 else src

    with open(src, "r", encoding="utf-8") as f:
        raw = f.read()

    stripped = strip_jsonc(raw)

    try:
        json.loads(stripped)
    except json.JSONDecodeError as e:
        sys.stderr.write(
            "ERROR: %s did not yield valid JSON after comment stripping: %s\n"
            % (src, e)
        )
        return 1

    if check_only:
        print("OK: %s is valid JSONC (parses as strict JSON once stripped)" % src)
        return 0

    with open(dst, "w", encoding="utf-8") as f:
        f.write(stripped)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
