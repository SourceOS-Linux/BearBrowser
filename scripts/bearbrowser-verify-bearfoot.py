#!/usr/bin/env python3
"""bearfoot — the print must be the same print.

A bear is *plantigrade*: it walks on the whole sole, heel to toe, as we do. Its hind track is
startlingly like a barefoot human print, and that resemblance is why peoples across the northern
hemisphere name the bear kin — the one who walks like a man. You cannot read a bear's track and
tell it from a person's, and you cannot read one bear's track and tell it from another's.

That is exactly what anti-fingerprinting is for. It does not hide the track. **It makes every track
the same track**, so no single print identifies anyone. A print that distinguishes you is a print
that betrays you.

Which yields a real invariant, and the reason this file is a checker rather than a comment:

    THE BEARFOOT PROPERTY — every BearBrowser profile that flattens its print must flatten it
    THE SAME WAY. If `human-secure` and `agent-runtime` disagree on a print-surface pref, that
    disagreement is itself a distinguishing bit: an observer cannot tell you apart from other
    users, but CAN tell which BearBrowser profile you run. The herd only protects you if the
    herd is uniform.

Fail-closed: a profile that claims the property and omits a pref is refused, and so is a profile
that sets one to a different value than its siblings. Silence is not agreement.

stdlib only. Usage:  python3 scripts/bearbrowser-verify-bearfoot.py [--json]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Profiles that assert the bearfoot property. A profile listed here MUST carry every pref below,
# and must agree with its siblings on the value.
BEARFOOT_PROFILES = [
    "settings/profiles/human-secure/user.js",
    "settings/profiles/agent-runtime/user.js",
]

# The print surface. Each of these is a bit an observer could otherwise read off one browser and
# not another.
PRINT_SURFACE = [
    "privacy.resistFingerprinting",
    "privacy.resistFingerprinting.letterboxing",
    "privacy.trackingprotection.fingerprinting.enabled",
]

PREF_RE = re.compile(r'user_pref\(\s*"([^"]+)"\s*,\s*([^)]+?)\s*\)\s*;')


def read_prefs(path: Path) -> dict[str, str]:
    """Parse user_pref() calls, ignoring commented-out lines."""
    prefs: dict[str, str] = {}
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue
        m = PREF_RE.search(line)
        if m:
            prefs[m.group(1)] = m.group(2).strip()
    return prefs


def check() -> list[str]:
    """Returns a list of violations; empty means the bearfoot property holds."""
    violations: list[str] = []
    seen: dict[str, dict[str, str]] = {}

    for rel in BEARFOOT_PROFILES:
        path = ROOT / rel
        if not path.exists():
            violations.append(f"{rel}: claims the bearfoot property but the file is missing")
            continue
        prefs = read_prefs(path)
        seen[rel] = {}
        for key in PRINT_SURFACE:
            if key not in prefs:
                violations.append(
                    f"{rel}: does not set {key} — a profile that claims the bearfoot property and "
                    "omits a print-surface pref leaves a track its siblings do not"
                )
                continue
            seen[rel][key] = prefs[key]

    # the herd only protects you if the herd is uniform
    for key in PRINT_SURFACE:
        values = {rel: p[key] for rel, p in seen.items() if key in p}
        if len(set(values.values())) > 1:
            detail = ", ".join(f"{Path(r).parent.name}={v}" for r, v in sorted(values.items()))
            violations.append(
                f"{key}: profiles disagree ({detail}) — the disagreement is itself a distinguishing "
                "bit, so an observer learns which BearBrowser you run"
            )
    return violations


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="bearbrowser-verify-bearfoot")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    violations = check()
    if a.json:
        print(json.dumps({"ok": not violations, "violations": violations,
                          "profiles": BEARFOOT_PROFILES, "print_surface": PRINT_SURFACE}, indent=2))
    else:
        for v in violations:
            print(f"  ✗ {v}", file=sys.stderr)
        if violations:
            print(f"\nbearfoot: REFUSED — {len(violations)} distinguishing difference(s). "
                  "Every bear must leave the same track.", file=sys.stderr)
        else:
            print(f"bearfoot: {len(BEARFOOT_PROFILES)} profiles, {len(PRINT_SURFACE)} print-surface "
                  "prefs, no distinguishing difference — the herd is uniform.", file=sys.stderr)
    return 1 if violations else 0


if __name__ == "__main__":
    raise SystemExit(main())
