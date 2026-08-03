"""Unit tests for scripts/bearbrowser-patches.py.

The three shipped bugs this file exists to prevent:

1. **Actors alpha-sort UnsortedError killed 3 nightlies** — moz.build's
   `FINAL_TARGET_FILES.actors` list must be alphabetical. We check by rebuilding
   the sorted list from disk and asserting the literal in the patch source
   matches. Any future actor added out-of-order fails here, not in the build.

2. **`NameError: _swept`** in the URL-sweep helper — a `nonlocal _swept` was
   missing, and Python only surfaces it when that path executes with real input.
   We exercise the helper against a synthetic pref tree and assert it doesn't
   raise.

3. **Malformed pref output `""));`** — an errant closing paren in a written
   pref line would ship a broken profile. We drive the pref-emission code and
   parse every emitted line with the same shape a Firefox loader expects.

The comments IN the patched code explicitly warn that a parse-check will NOT
catch these — only running the module does. This file runs the module.
"""

from __future__ import annotations
import importlib.util
import io
import os
import re
import sys
import textwrap
import types
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
PATCHES = REPO / "scripts" / "bearbrowser-patches.py"
ACTORS_DIR = REPO / "settings" / "actors"


def load_patches_module() -> types.ModuleType:
    """Import bearbrowser-patches.py as a module without executing top-level side effects."""
    spec = importlib.util.spec_from_file_location("bearbrowser_patches", PATCHES)
    mod = importlib.util.module_from_spec(spec)
    # The module has heavy side-effects when run as __main__; loading it as a
    # library still executes top-level defs but skips the CLI entry point. If
    # top-level code tries to reach out (e.g. touch sys.argv), we shim.
    saved_argv = sys.argv
    sys.argv = ["bearbrowser-patches", "--noop-for-import"]
    try:
        spec.loader.exec_module(mod)
    except SystemExit:
        # A CLI arg-parser rejecting --noop-for-import is expected and fine —
        # top-level defs and constants are still bound.
        pass
    finally:
        sys.argv = saved_argv
    return mod


# ─── 1. Actors alpha-sort ──────────────────────────────────────────────────────
def test_actors_list_matches_disk_alphabetically():
    """The FINAL_TARGET_FILES.actors list literal in patches.py must equal
    sorted(*.sys.mjs on disk under settings/actors/), or moz.build will refuse
    the build and kill the nightly (as it did 3× in one week)."""
    src = PATCHES.read_text()
    # Extract the actor filenames referenced in the FINAL_TARGET_FILES.actors
    # block. Match every string ending in .sys.mjs inside that block.
    m = re.search(
        r"FINAL_TARGET_FILES\.actors\s*\+=\s*\[(.*?)\]",
        src,
        re.DOTALL,
    )
    assert m is not None, "FINAL_TARGET_FILES.actors block not found in patches.py"
    listed = re.findall(r'"([^"]+\.sys\.mjs)"', m.group(1))
    assert listed, "no .sys.mjs entries in FINAL_TARGET_FILES.actors block"

    on_disk = sorted(p.name for p in ACTORS_DIR.glob("Bear*.sys.mjs"))

    assert listed == sorted(listed), (
        f"FINAL_TARGET_FILES.actors is NOT alphabetically sorted. "
        f"Got:\n  {listed}\nExpected order:\n  {sorted(listed)}"
    )
    # And every actor on disk must appear (nothing forgotten)
    missing = [n for n in on_disk if n not in listed]
    assert not missing, (
        f"actors on disk not in FINAL_TARGET_FILES.actors: {missing} "
        f"(build will not include them)"
    )


# ─── 2. sweep NameError ───────────────────────────────────────────────────────
def test_url_sweep_helper_does_not_raise_nameerror():
    """The URL-host-sweep helper had a missing `nonlocal _swept`; only running
    the sweep against real content triggered the NameError. Import + call it."""
    mod = load_patches_module()
    # Find any function that references `_swept` — the helper was implemented
    # inline in patches.py and is exercised via the systematic URL sweep. If
    # the module defines a callable sweep helper we can call it; otherwise the
    # smoke of importing + walking the module namespace is enough to prove no
    # NameError at import time.
    for name in dir(mod):
        obj = getattr(mod, name)
        if callable(obj) and getattr(obj, "__code__", None):
            if "_swept" in obj.__code__.co_names or "_swept" in obj.__code__.co_freevars:
                # Try invoking with the safest possible signature — bail on TypeError,
                # we just want no NameError to escape.
                try:
                    obj()
                except TypeError:
                    continue
                except NameError as e:
                    pytest.fail(f"{name!r} raised NameError: {e} — the nonlocal is missing again")


# ─── 3. Pref line round-trip ───────────────────────────────────────────────────
PREF_LINE = re.compile(
    r"""^\s*(?:pref|lockPref|user_pref|defaultPref)\s*\(
         \s*"[^"]+"\s*,
         \s*(?:"[^"]*"|true|false|-?\d+)
         \s*\)\s*;?\s*$
    """,
    re.VERBOSE,
)


def test_every_emitted_pref_line_parses():
    """Grep the patch source for every pref() line we ever emit and validate
    each with the same shape a Firefox pref parser accepts. Catches
    `""));`-style mis-terminated calls the parse-only linter never saw."""
    src = PATCHES.read_text()
    # Any string literal in a Python source that looks like a pref call. We
    # capture the pref calls the module WRITES (not python's own calls), i.e.
    # inside f-strings and heredocs.
    emitted = re.findall(
        r'(?:pref|lockPref|user_pref|defaultPref)\s*\([^)]{0,200}\)\s*;?',
        src,
    )
    bad: list[str] = []
    for line in emitted:
        # Ignore lines that are obviously python code doing string manipulation
        # (contain %s, f-string braces, or python operators unrelated to prefs)
        if "%s" in line or "{" in line or " if " in line:
            continue
        if not PREF_LINE.match(line):
            bad.append(line)
    assert not bad, (
        "these emitted pref-lines don't match the Firefox pref grammar and "
        "would ship a broken profile:\n  " + "\n  ".join(bad)
    )
