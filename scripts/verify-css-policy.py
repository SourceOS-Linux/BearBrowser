#!/usr/bin/env python3
"""Verify BearBrowser CSS-policy sanitizer + deception-signal fixtures (threat-model deltas).

CSS policy is an ALLOW-LIST (anything unlisted is blocked). Beyond schema conformance this enforces,
fail-closed, that the allow-list NEVER contains the known deception CSS vectors (filter family and
blend modes) — those are always blocked regardless of the skin — and that the z-index cap is set.
Deception signals must carry a known signalType + severity. Self-testing: valid fixtures pass; a
policy that allows `filter` and a signal with an unknown type are refused.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CSS_SCHEMA = ROOT / "schemas" / "css-policy.schema.json"
SIG_SCHEMA = ROOT / "schemas" / "deception-signal.schema.json"
CSS_VALID = ROOT / "examples" / "css-policy.valid.json"
CSS_INVALID = ROOT / "examples" / "css-policy.allows-filter.invalid.json"
SIG_VALID = ROOT / "examples" / "deception-signal.zindex-spike.valid.json"
SIG_INVALID = ROOT / "examples" / "deception-signal.bad-type.invalid.json"

# CSS properties that are deception/clickjacking vectors and must NEVER be in a skin's allow-list.
FORBIDDEN_CSS = {"filter", "-webkit-filter", "backdrop-filter", "-webkit-backdrop-filter",
                 "mix-blend-mode", "background-blend-mode"}
SIGNAL_TYPES = {"z-index-spike", "offscreen-link", "pointer-events-trap", "position-fixed-overlay", "has-deception"}
SEVERITIES = {"low", "medium", "high"}


class PolicyError(Exception):
    pass


def load(p: Path) -> Any:
    return json.loads(p.read_text(encoding="utf-8"))


def require(c: bool, m: str) -> None:
    if not c:
        raise PolicyError(m)


def validate_css(rec: Any) -> None:
    require(isinstance(rec, dict) and rec.get("kind") == "CssPolicy", "not a CssPolicy")
    require(bool(rec.get("policyId")), "policyId required")
    allowed = rec.get("allowedProperties")
    require(isinstance(allowed, list) and allowed, "allowedProperties must be a non-empty allow-list")
    bad = sorted(FORBIDDEN_CSS & set(allowed))
    require(not bad, f"allow-list contains deception CSS vectors that must always be blocked: {bad}")
    require(isinstance(rec.get("zIndexCap"), int) and 0 <= rec["zIndexCap"] <= 100000, "zIndexCap must be a bounded integer")
    require(isinstance(rec.get("overlays", {}).get("positionFixedAllowed"), bool), "overlays.positionFixedAllowed required")
    require(isinstance(rec.get("hasSelector", {}).get("allowed"), bool), "hasSelector.allowed required")


def validate_signal(rec: Any) -> None:
    require(isinstance(rec, dict) and rec.get("kind") == "DeceptionSignal", "not a DeceptionSignal")
    require(rec.get("signalType") in SIGNAL_TYPES, f"signalType must be one of {sorted(SIGNAL_TYPES)}")
    require(rec.get("severity") in SEVERITIES, f"severity must be one of {sorted(SEVERITIES)}")
    require(bool(rec.get("evidence", {}).get("detail")), "evidence.detail required")


def expect_reject(path: Path, fn) -> str | None:
    try:
        fn(load(path))
        return f"expected {path.name} to be rejected, but it passed"
    except PolicyError:
        return None


def main() -> int:
    fails = []
    try:
        validate_css(load(CSS_VALID))
        validate_signal(load(SIG_VALID))
    except PolicyError as exc:
        fails.append(f"valid fixture failed: {exc}")
    for path, fn in ((CSS_INVALID, validate_css), (SIG_INVALID, validate_signal)):
        m = expect_reject(path, fn)
        if m:
            fails.append(m)
    for m in fails:
        print(f"ERR: {m}", file=sys.stderr)
    if fails:
        return 2
    print("OK: CSS policy + deception signal validated (2 valid, 2 invalid rejected)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
