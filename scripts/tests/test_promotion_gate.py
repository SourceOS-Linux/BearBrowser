"""Gate-of-the-gate — pytest for promotion-gate.yml's HEART logic.

promotion-gate.yml false-negatived twice on v150.0.6 in one hour:

  1. First run  127'd on `7zz: command not found` — hardcoded a binary
     that exists only on Ubuntu 24+ (`7zip` package), while ubuntu-latest
     is 22.04 (`p7zip-full`, binary `7z`).
  2. Retry silently returned empty version — `plistutil` failed silently,
     `grep` matched the binary blob, `sed` yielded nothing. Comparison
     `'' != '150.0.6'` → quarantined a **good** artifact.

Both would have been caught in the PR that introduced them, in seconds,
if the gate's own logic had been unit-tested. This is that unit test.

Fixtures are generated in-memory: no committed binary blobs. Runs on
ubuntu-latest with only plistlib (stdlib) — no external deps.
"""
from __future__ import annotations
import plistlib
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]


# ── plist-version extraction (the exact logic in promotion-gate.yml) ──────────
def extract_plist_version(plist_bytes: bytes) -> str:
    """Return CFBundleShortVersionString or '' — the shape promotion-gate uses."""
    import io
    d = plistlib.load(io.BytesIO(plist_bytes))
    return d.get("CFBundleShortVersionString", "")


def make_plist(version: str, fmt=plistlib.FMT_BINARY) -> bytes:
    """Build an Info.plist fixture matching a real BearBrowser.app plist."""
    d = {
        "CFBundleName": "BearBrowser",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": version,
        "CFBundleIdentifier": "dev.sourceos.BearBrowser",
    }
    return plistlib.dumps(d, fmt=fmt)


def test_extract_from_binary_plist_matches():
    """The failure mode: real DMGs ship BINARY plists. plistutil silently
    failed to convert; grep|sed on binary returned empty. plistlib handles
    binary natively."""
    plist = make_plist("150.0.6", plistlib.FMT_BINARY)
    assert extract_plist_version(plist) == "150.0.6"


def test_extract_from_xml_plist_matches():
    plist = make_plist("150.0.6", plistlib.FMT_XML)
    assert extract_plist_version(plist) == "150.0.6"


def test_mismatch_is_detected():
    """The gate's actual purpose: catch a plist that doesn't match the tag."""
    plist = make_plist("150.0.1", plistlib.FMT_BINARY)  # the 4-release lie
    assert extract_plist_version(plist) != "150.0.6"


def test_missing_key_returns_empty_not_crash():
    """A malformed plist without CFBundleShortVersionString must yield '',
    not a KeyError — so the gate can report a meaningful error instead of
    a Python traceback that masks the real problem."""
    plist = plistlib.dumps({"CFBundleName": "BearBrowser"}, fmt=plistlib.FMT_BINARY)
    assert extract_plist_version(plist) == ""


# ── update-check hygiene grep (the OTHER thing the gate checks) ───────────────
UPDATE_HYGIENE_KEYWORDS = ("credentials:\"omit\"", "referrerPolicy", "no-referrer")


def hygiene_check(cfg_text: str) -> tuple[bool, list[str]]:
    """The exact assertions promotion-gate.yml runs against the shipped .cfg."""
    missing = []
    if 'credentials:"omit"' not in cfg_text and "credentials: \"omit\"" not in cfg_text:
        missing.append("credentials:omit")
    if "referrerPolicy" not in cfg_text:
        missing.append("referrerPolicy")
    if "no-referrer" not in cfg_text:
        missing.append("no-referrer")
    return (len(missing) == 0, missing)


def test_hygiene_passes_when_all_keywords_present():
    cfg = 'fetch(url, { credentials:"omit", referrerPolicy: "no-referrer" })'
    ok, missing = hygiene_check(cfg)
    assert ok, f"unexpected missing: {missing}"


def test_hygiene_fails_when_credentials_absent():
    cfg = 'fetch(url, { referrerPolicy: "no-referrer" })'
    ok, missing = hygiene_check(cfg)
    assert not ok
    assert "credentials:omit" in missing


def test_hygiene_fails_when_referrer_policy_absent():
    cfg = 'fetch(url, { credentials:"omit" })'
    ok, missing = hygiene_check(cfg)
    assert not ok
    assert "referrerPolicy" in missing or "no-referrer" in missing


def test_shipped_cfg_would_pass_hygiene_today():
    """Meta-check: the currently-shipped bearstart-autoconfig.js MUST have
    all three hygiene keywords. If this ever fails, we've regressed the
    v150.0.5 fix. (This is the same class of assertion the shipped
    verify-package.sh does — we're asserting the source-of-truth here.)"""
    src = (REPO / "settings" / "start" / "bearstart-autoconfig.js").read_text()
    ok, missing = hygiene_check(src)
    assert ok, f"shipped bearstart-autoconfig.js regressed update-fetch hygiene: missing {missing}"


# ── 7z binary detection (the FIRST thing that broke) ──────────────────────────
def which(cmd: str) -> str | None:
    """Cross-platform which — the same detection promotion-gate.yml now does."""
    r = subprocess.run(["command", "-v", cmd], shell=True, capture_output=True)
    return r.stdout.decode().strip() or None


@pytest.mark.skipif(sys.platform != "linux", reason="only care about the CI-runner shape")
def test_at_least_one_7z_binary_findable_after_install():
    """On Ubuntu 22.04 the correct package is p7zip-full (binary `7z`),
    NOT `7zip` (binary `7zz`, Ubuntu 24+). The gate's detect-first-available
    loop is what unblocks this. If NONE of the candidates work, the gate
    step will exit 127 like it did on v150.0.6.

    We don't install here — CI installs it before this test runs. We just
    assert the detect loop finds SOMETHING."""
    candidates = ["7z", "7zz", "7za"]
    found = [c for c in candidates if subprocess.run(
        ["bash", "-c", f"command -v {c}"], capture_output=True
    ).returncode == 0]
    assert found, (
        f"no 7z-family binary in PATH after apt install — the promotion-gate "
        f"step would 127 like it did on v150.0.6. Install `p7zip-full`."
    )


# ── Gate workflow's structure (guard against future edits removing gates) ─────
GATE_YAML = REPO / ".github" / "workflows" / "promotion-gate.yml"


def test_gate_workflow_still_has_all_five_load_bearing_steps():
    """If someone deletes or renames one of these steps, the gate silently
    stops catching that class of bug. Name-based assertion so a rename
    surfaces here, not on a release-publish."""
    src = GATE_YAML.read_text()
    required = [
        "Resolve tag + download release artifacts",
        "Package gate (Linux tarball)",
        "Info.plist version gate (macOS DMG)",
        "Update-check network hygiene smoke",
        "quarantine-on-failure",  # job, not step — but same principle
    ]
    for name in required:
        assert name in src, f"promotion-gate.yml missing load-bearing step: {name!r}"


def test_gate_workflow_uses_plistlib_not_grep_sed():
    """The v150.0.6 grep|sed failure must not be reintroduced. If someone
    goes back to the fragile chain, this fails."""
    src = GATE_YAML.read_text()
    assert "plistlib" in src, "promotion-gate.yml regressed off plistlib for Info.plist parsing"


def test_gate_workflow_does_not_hardcode_7zz():
    """Detect-loop must stay in place; hardcoding one 7z binary killed v150.0.6."""
    src = GATE_YAML.read_text()
    # The bad pattern was a bare `7zz x` command. The safe pattern uses a
    # detected variable. We check that the extraction call goes through the
    # variable, not a bare 7zz command.
    bad_lines = [
        line for line in src.splitlines()
        if re.search(r"^\s*7zz\s+x\b", line)  # bare 7zz x, not detected
    ]
    assert not bad_lines, (
        f"promotion-gate.yml regressed to hardcoded 7zz — will 127 on Ubuntu 22.04. "
        f"Bad lines: {bad_lines}"
    )
