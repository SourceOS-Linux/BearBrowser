#!/usr/bin/env python3
"""Verify BearBrowser runtime boundary decision fixtures."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "browser-runtime-boundary-decision.schema.json"
VALID = ROOT / "examples" / "browser-runtime-boundary.agent-automation.valid.json"
INVALID_CREDENTIAL_EXPORT = ROOT / "examples" / "browser-runtime-boundary.credential-export.invalid.json"
INVALID_RAW_SECRET = ROOT / "examples" / "browser-runtime-boundary.raw-secret.invalid.json"

REQUIRED = {
    "schemaVersion",
    "kind",
    "decisionId",
    "surface",
    "actor",
    "requestedAction",
    "policyDecisionId",
    "credentialBoundary",
    "automationBoundary",
    "workspaceBoundary",
    "redactionBoundary",
    "performedAction",
    "evidenceRefs",
}


class BoundaryError(Exception):
    pass


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise BoundaryError(f"{path.relative_to(ROOT)}: expected object")
    return payload


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BoundaryError(message)


def validate_schema(schema: dict[str, Any]) -> None:
    require(schema.get("$schema") == "https://json-schema.org/draft/2020-12/schema", "schema draft mismatch")
    require(schema.get("additionalProperties") is False, "schema must be closed")


def validate_boundary(path: Path, record: dict[str, Any]) -> None:
    missing = sorted(REQUIRED - set(record))
    require(not missing, f"{path}: missing fields: {missing}")
    require(record.get("schemaVersion") == "bearbrowser.runtime-boundary.v1", f"{path}: schemaVersion mismatch")
    require(record.get("kind") == "BrowserRuntimeBoundaryDecision", f"{path}: kind mismatch")
    require(record.get("performedAction") is False, f"{path}: boundary record must not perform browser action")
    require(str(record.get("policyDecisionId", "")).startswith("policy-decision://"), f"{path}: policyDecisionId required")

    actor = record.get("actor", {})
    require(isinstance(actor, dict), f"{path}: actor must be object")
    if actor.get("type") == "agent":
        require(actor.get("agentRegistryRef"), f"{path}: agent actor requires Agent Registry ref")

    credential = record.get("credentialBoundary", {})
    require(credential.get("credentialExportAllowed") is False, f"{path}: credential export must remain denied")
    require(credential.get("inheritsHumanCredentials") is False, f"{path}: agent runtime must not inherit human credentials")

    automation = record.get("automationBoundary", {})
    require(automation.get("nonLoopbackControlAllowed") is False, f"{path}: non-loopback control must remain denied")
    require(automation.get("nativeExecutionAllowed") is False, f"{path}: native execution must remain denied")

    workspace = record.get("workspaceBoundary", {})
    require(workspace.get("declaredWorkspaceScopeOnly") is True, f"{path}: workspace bridge must stay declared-scope only")

    redaction = record.get("redactionBoundary", {})
    require(redaction.get("secretValuesLogged") is False, f"{path}: secret values must not be logged")
    require(redaction.get("sessionMaterialLogged") is False, f"{path}: session material must not be logged")
    require(redaction.get("paymentMaterialLogged") is False, f"{path}: payment material must not be logged")

    evidence_refs = record.get("evidenceRefs", [])
    require(isinstance(evidence_refs, list) and evidence_refs, f"{path}: evidenceRefs required")
    for ref in evidence_refs:
        require(isinstance(ref, str) and ref.startswith("evidence://"), f"{path}: evidence refs must be evidence://")


def expect_invalid(path: Path) -> None:
    try:
        validate_boundary(path.relative_to(ROOT), load_json(path))
    except BoundaryError:
        return
    raise BoundaryError(f"invalid fixture unexpectedly validated: {path.relative_to(ROOT)}")


def main() -> int:
    try:
        validate_schema(load_json(SCHEMA))
        validate_boundary(VALID.relative_to(ROOT), load_json(VALID))
        expect_invalid(INVALID_CREDENTIAL_EXPORT)
        expect_invalid(INVALID_RAW_SECRET)
    except (OSError, json.JSONDecodeError, BoundaryError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    print("BearBrowser runtime boundary fixtures verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
