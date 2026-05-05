#!/usr/bin/env python3
"""Verify BearBrowser agent-sidecar contract invariants without external deps."""
from __future__ import annotations

import re
import sys
from pathlib import Path

CONTRACT = Path("agent-sidecar/contract.yaml")
REQUIRED_TEXT = {
    "defaultMode: observe": "default mode must be observe",
    "memoryDefault: candidateOnly": "memory default must be candidateOnly",
    "credentialDefault: denyForAgentRuntime": "credential default must deny agent-runtime credentials",
    "tabSharingDefault: explicitSelectionOnly": "tab sharing must be explicit selection only",
    "logSecretValues: false": "secret values must not be logged",
    "logCredentialValues: false": "credential values must not be logged",
    "logPaymentValues: false": "payment values must not be logged",
    "logCookieValues: false": "cookie values must not be logged",
    "requiredForMutation: true": "PolicyFabric must be required for mutation",
    "requiredForCredentialAccess: true": "PolicyFabric must be required for credential access",
    "requiredForCrossTabSharing: true": "PolicyFabric must be required for cross-tab sharing",
}
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
MUTATION_SURFACES = {"action-proposal", "memory-candidate"}
APPROVAL_SURFACES = {"selected-tab-compare", "action-proposal", "memory-candidate"}


def block_for_surface(text: str, surface_id: str) -> str:
    pattern = rf"(?ms)^    - id: {re.escape(surface_id)}\n(.*?)(?=^    - id: |^  modes:|^  redaction:|^  integration:|\Z)"
    match = re.search(pattern, text)
    return match.group(0) if match else ""


def main() -> int:
    if not CONTRACT.exists():
        print(f"ERROR: missing {CONTRACT}", file=sys.stderr)
        return 1

    text = CONTRACT.read_text(encoding="utf-8")
    errors: list[str] = []

    for required, message in REQUIRED_TEXT.items():
        if required not in text:
            errors.append(message)

    for surface in sorted(REQUIRED_SURFACES):
        block = block_for_surface(text, surface)
        if not block:
            errors.append(f"missing required surface: {surface}")
            continue
        if "policyAction:" not in block:
            errors.append(f"{surface}: missing policyAction")
        if "provenanceEvents:" not in block:
            errors.append(f"{surface}: missing provenanceEvents")
        if surface in MUTATION_SURFACES and "defaultDecision: hold" not in block:
            errors.append(f"{surface}: mutation-capable surfaces must default to hold")
        if surface in APPROVAL_SURFACES and "requiresUserApproval: true" not in block:
            errors.append(f"{surface}: must require user approval")
        if surface == "credential-boundary":
            if "defaultDecision: deny" not in block:
                errors.append("credential-boundary must default deny")
            if "agent-runtime" not in block:
                errors.append("credential-boundary must explicitly apply to agent-runtime")

    for event in sorted(REQUIRED_EVENTS):
        if event not in text:
            errors.append(f"missing required provenance event: {event}")

    if "Agents observe and propose; PolicyFabric and the user grant authority." not in text:
        errors.append("missing sidecar authority principle")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("BearBrowser agent sidecar contract verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
