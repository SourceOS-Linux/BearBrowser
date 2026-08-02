#!/usr/bin/env python3
"""Enforce BearBrowser's consent-plane surface envelope (browser = containment-critical).

The browser surface takes UNTRUSTED web content as input, so its envelope must
keep it pinned to agent-space and forbid implement/operate. This check FAILS
CI if anyone weakens those invariants — the boundary is enforced in-repo, not
just declared. Conforms to socioprophet-agent-standards consent-plane/001 and
the sourceos-spec isolation-spaces contract.
"""
from __future__ import annotations

import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except Exception as exc:  # pragma: no cover
    raise SystemExit("PyYAML is required (pip install pyyaml)") from exc

ROOT = Path(__file__).resolve().parents[1]
NON_AGENT_SPACES = {"kernel-space", "system-space", "user-space", "data-namespace"}
MUST_DENY_PURPOSES = {"implement", "operate"}
ALLOWED_PURPOSES = {"discover", "egress"}


def main() -> int:
    doc = yaml.safe_load((ROOT / "TRUST_SURFACE.yaml").read_text())
    cp = (doc or {}).get("consent_plane")
    errors: list[str] = []

    if not cp:
        print("ERR: TRUST_SURFACE.yaml has no consent_plane block", file=sys.stderr)
        return 1

    if cp.get("surface_id") != "browser":
        errors.append(f"surface_id must be 'browser', got {cp.get('surface_id')!r}")
    if cp.get("untrusted_input") is not True:
        errors.append("untrusted_input must be true (web content is untrusted)")

    deny = set(cp.get("deny_purposes") or [])
    if not MUST_DENY_PURPOSES <= deny:
        errors.append(f"deny_purposes must include {sorted(MUST_DENY_PURPOSES)}; got {sorted(deny)}")

    purposes = set(cp.get("purposes") or [])
    if not purposes <= ALLOWED_PURPOSES:
        errors.append(f"purposes must be a subset of {sorted(ALLOWED_PURPOSES)}; got {sorted(purposes)}")

    space_deny = set(cp.get("space_deny") or [])
    missing = NON_AGENT_SPACES - space_deny
    if missing:
        errors.append(f"space_deny must contain every non-agent space (pin to agent-space); "
                      f"missing {sorted(missing)}")

    if errors:
        print("FAIL: BearBrowser consent-plane surface envelope violated:", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1
    print("OK: browser surface pinned to agent-space; implement/operate denied; untrusted input.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
