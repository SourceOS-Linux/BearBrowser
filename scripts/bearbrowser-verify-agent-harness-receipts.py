#!/usr/bin/env python3
"""Verify BearBrowser Agent Harness receipt fixture."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "agent-harness-browser-receipts.schema.json"
EXAMPLE = ROOT / "examples" / "agent-harness-browser-receipts.example.json"


class ValidationError(Exception):
    pass


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def validate(data: dict[str, Any]) -> None:
    require(data.get("schemaVersion") == "v0.1", "schemaVersion must be v0.1")
    require(data.get("kind") == "AgentHarnessBrowserReceipts", "kind mismatch")

    session = data.get("browserSessionReceipt")
    require(isinstance(session, dict), "browserSessionReceipt must be object")
    for field in ["sessionId", "actorRef", "workspaceRef", "runtimeProfile", "policyAdmissionRef", "networkProfile", "credentialPosture", "mode", "agentplaneRunRef"]:
        require(field in session, f"browserSessionReceipt missing {field}")
    require(session["mode"] in {"visible", "headless"}, "invalid session mode")
    require(session["credentialPosture"] in {"none", "available-but-unused", "used-with-policy", "blocked"}, "invalid credential posture")

    action = data.get("browserActionReceipt")
    require(isinstance(action, dict), "browserActionReceipt must be object")
    for field in ["actionId", "browserSessionRef", "url", "actionType", "sideEffectClass", "policyDecisionRef", "credentialUse", "resultStatus"]:
        require(field in action, f"browserActionReceipt missing {field}")
    require(action["policyDecisionRef"], "browser action requires policyDecisionRef")
    if action["credentialUse"]:
        require(action["sideEffectClass"] == "credential", "credential action must use sideEffectClass=credential")

    download = data.get("browserDownloadReceipt")
    require(isinstance(download, dict), "browserDownloadReceipt must be object")
    for field in ["downloadId", "sourceUrl", "sha256", "mediaType", "sizeBytes", "quarantineState", "memoryMeshPointerRef", "policyDecisionRef"]:
        require(field in download, f"browserDownloadReceipt missing {field}")
    require(download["quarantineState"] in {"not-required", "quarantined", "released", "blocked"}, "invalid quarantine state")

    credential = data.get("browserCredentialUseReceipt")
    require(isinstance(credential, dict), "browserCredentialUseReceipt must be object")
    for field in ["credentialEventId", "browserSessionRef", "credentialScope", "policyDecisionRef", "rawCredentialStored", "resultStatus"]:
        require(field in credential, f"browserCredentialUseReceipt missing {field}")
    require(credential["rawCredentialStored"] is False, "raw credentials must not be stored")


def main() -> int:
    try:
        if not SCHEMA.exists():
            raise ValidationError(f"missing schema: {SCHEMA}")
        data = load_json(EXAMPLE)
        validate(data)
    except (json.JSONDecodeError, ValidationError) as exc:
        print(f"BearBrowser Agent Harness receipt validation failed: {exc}", file=sys.stderr)
        return 1
    print("OK: BearBrowser Agent Harness receipt fixture validates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
