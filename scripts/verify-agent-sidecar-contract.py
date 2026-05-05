#!/usr/bin/env python3
"""Verify BearBrowser agent-sidecar contract invariants."""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    raise SystemExit("ERROR: PyYAML is required for agent-sidecar contract verification") from exc

CONTRACT = Path("agent-sidecar/contract.yaml")
REQUIRED_SURFACES = {
    "current-page-summary",
    "selected-tab-compare",
    "action-proposal",
    "memory-candidate",
    "credential-boundary",
}
REQUIRED_EVENTS = {
    "automation.observed",
    "page.shared_with_agent",
    "automation.action_requested",
    "automation.action_approved",
    "automation.action_denied",
    "memory.candidate_created",
    "memory.committed",
    "memory.rejected",
    "credential.requested",
    "credential.granted",
    "credential.denied",
}


def main() -> int:
    if not CONTRACT.exists():
        print(f"ERROR: missing {CONTRACT}", file=sys.stderr)
        return 1

    data: dict[str, Any] = yaml.safe_load(CONTRACT.read_text())
    spec = data.get("spec", {})
    errors: list[str] = []

    if spec.get("defaultMode") != "observe":
        errors.append("defaultMode must be observe")
    if spec.get("memoryDefault") != "candidateOnly":
        errors.append("memoryDefault must be candidateOnly")
    if spec.get("credentialDefault") != "denyForAgentRuntime":
        errors.append("credentialDefault must be denyForAgentRuntime")
    if spec.get("tabSharingDefault") != "explicitSelectionOnly":
        errors.append("tabSharingDefault must be explicitSelectionOnly")

    surfaces = spec.get("surfaces", [])
    by_id = {surface.get("id"): surface for surface in surfaces}
    missing = sorted(REQUIRED_SURFACES - set(by_id))
    if missing:
        errors.append(f"missing required surfaces: {', '.join(missing)}")

    seen_events: set[str] = set()
    for surface in surfaces:
        sid = surface.get("id", "<unknown>")
        default_decision = surface.get("defaultDecision")
        policy_action = surface.get("policyAction")
        if not policy_action:
            errors.append(f"{sid}: missing policyAction")
        seen_events.update(surface.get("provenanceEvents", []))
        if surface.get("writes") and default_decision != "hold":
            errors.append(f"{sid}: writing surfaces must default to hold")
        if sid == "credential-boundary" and default_decision != "deny":
            errors.append("credential-boundary must default deny")
        if sid == "selected-tab-compare" and surface.get("requiresUserApproval") is not True:
            errors.append("selected-tab-compare must require user approval")
        if sid == "action-proposal" and surface.get("requiresUserApproval") is not True:
            errors.append("action-proposal must require user approval")
        if sid == "memory-candidate" and surface.get("requiresUserApproval") is not True:
            errors.append("memory-candidate must require user approval")

    missing_events = sorted(REQUIRED_EVENTS - seen_events)
    if missing_events:
        errors.append(f"missing required provenance events: {', '.join(missing_events)}")

    redaction = spec.get("redaction", {})
    for key in ["logSecretValues", "logCredentialValues", "logPaymentValues", "logCookieValues"]:
        if redaction.get(key) is not False:
            errors.append(f"redaction.{key} must be false")

    integration = spec.get("integration", {})
    policy = integration.get("policyFabric", {})
    if policy.get("requiredForMutation") is not True:
        errors.append("PolicyFabric must be required for mutation")
    if policy.get("requiredForCredentialAccess") is not True:
        errors.append("PolicyFabric must be required for credential access")
    if policy.get("requiredForCrossTabSharing") is not True:
        errors.append("PolicyFabric must be required for cross-tab sharing")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("BearBrowser agent sidecar contract verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
