#!/usr/bin/env python3
"""Convert a BearBrowser profile user.js into a Firefox autoconfig (.cfg) file.

BearBrowser ships its pref-layer hardening baseline as
settings/profiles/<profile>/user.js (all `user_pref(...)` statements). For those
prefs to take effect in a *packaged* build they must be compiled in, not dropped
into a profile directory. The mechanism already wired up in the build is the
LibreWolf-style autoconfig: lw/bearbrowser.cfg is packaged to the app root and
defaults/pref/local-settings.js points general.config.filename at it.

Neither an autoconfig file nor a default-pref file (browser/defaults/preferences/
*.js) defines `user_pref` — that function only exists for a profile's prefs.js.
Both contexts DO define `pref()`, which sets the pref on the default branch. This
converter rewrites each `user_pref("k", v);` to `pref("k", v);`, the faithful
translation of a user.js baseline: a default the browser ships, still overridable
where it is not separately enforced by an enterprise policy with "Locked": true.
Emitting `pref()` (rather than the autoconfig-only `defaultPref()`) keeps the
output valid in BOTH the autoconfig .cfg and the defaults/preferences/*.js paths.

Comment stripping is string-aware (it will not touch a "//" inside a value such
as "https://9.9.9.9/dns-query"), and the conversion is validated: the number of
emitted prefs must equal the number of user_pref statements in the source, or
the build fails loudly rather than silently shipping a partial pref set.

Usage:
    userjs-to-autoconfig.py SRC.user.js DST.cfg [--profile NAME]
"""

import importlib.util
import os
import re
import sys

# Reuse the string-aware // and /* */ stripper from the sibling helper. Its
# filename is hyphenated (not a valid module name) so load it by path.
_strip_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "strip-json-comments.py")
_spec = importlib.util.spec_from_file_location("strip_json_comments", _strip_path)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
strip_jsonc = _mod.strip_jsonc

# A single pref statement once comments are stripped: user_pref( ARGS );
_PREF_RE = re.compile(r"^\s*user_pref\((.*)\);\s*$")


def convert(userjs_text: str):
    expected = len(re.findall(r"\buser_pref\s*\(", userjs_text))
    stripped = strip_jsonc(userjs_text)

    out_lines = []
    for line in stripped.splitlines():
        if not line.strip():
            continue
        m = _PREF_RE.match(line)
        if not m:
            raise ValueError(
                "unrecognized non-pref content after comment stripping: %r" % line
            )
        out_lines.append("pref(%s);" % m.group(1).strip())

    if len(out_lines) != expected:
        raise ValueError(
            "converted %d prefs but source had %d user_pref statements"
            % (len(out_lines), expected)
        )
    return out_lines, expected


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    profile = "profile"
    for a in argv[1:]:
        if a.startswith("--profile="):
            profile = a.split("=", 1)[1]
    # also support "--profile NAME"
    if "--profile" in argv:
        i = argv.index("--profile")
        if i + 1 < len(argv):
            profile = argv[i + 1]
            args = [a for a in args if a != profile]

    if len(args) < 2:
        sys.stderr.write(__doc__)
        return 2

    src, dst = args[0], args[1]
    with open(src, "r", encoding="utf-8") as f:
        text = f.read()

    try:
        out_lines, n = convert(text)
    except ValueError as e:
        sys.stderr.write("ERROR converting %s: %s\n" % (src, e))
        return 1

    # The first line of an autoconfig file is ALWAYS skipped by Firefox, so it
    # must be a comment — never a pref.
    # NB: the first line is ALWAYS skipped when this file is used as a Firefox
    # autoconfig (general.config.filename), so it must be a comment.
    header = (
        "// BearBrowser default preferences — generated from profiles/%s/user.js\n"
        "// DO NOT EDIT: regenerate with scripts/userjs-to-autoconfig.py\n"
        % profile
    )
    with open(dst, "w", encoding="utf-8") as f:
        f.write(header)
        f.write("\n".join(out_lines))
        f.write("\n")

    print("userjs-to-autoconfig: %s -> %s (%d prefs)" % (src, dst, n))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
