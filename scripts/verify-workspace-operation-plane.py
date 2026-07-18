#!/usr/bin/env python3
"""Verify BearBrowser workspace operation plane contract invariants."""
from __future__ import annotations

import sys
from pathlib import Path

CONTRACT = Path("agentplane/workspace-operation-plane.yaml")
REQUIRED_TEXT = {
    "browser.session.start": "missing browser.session.start operation type",
    "browser.capture.create": "missing browser.capture.create operation type",
    "browser.download.create": "missing browser.download.create operation type",
    "browser.upload.create": "missing browser.upload.create operation type",
    "browser.automation.run": "missing browser.automation.run operation type",
    "browser.diagnostics.export_redacted": "missing browser.diagnostics.export_redacted operation type",
    "kind: BrowserSession": "missing BrowserSession artifact",
    "kind: WebCapture": "missing WebCapture artifact",
    "kind: DownloadArtifact": "missing DownloadArtifact artifact",
    "kind: UploadArtifact": "missing UploadArtifact artifact",
    "kind: BrowserAutomationRun": "missing BrowserAutomationRun artifact",
    "kind: BrowserDiagnosticBundle": "missing BrowserDiagnosticBundle artifact",
    "cookies: redact": "cookies must be redacted",
    "credentials: redact": "credentials must be redacted",
    "tokens: redact": "tokens must be redacted",
    "authHeaders: redact": "auth headers must be redacted",
    "prompts: redact": "prompts must be redacted",
    "sensitiveIds: redact": "sensitive IDs must be redacted",
    "policyAuthority: PolicyFabric": "PolicyFabric must remain policy authority",
    "No browser automation or capture creates durable workspace state outside the Operation Plane.": "missing durable state hard rule",
}
REQUIRED_LIFECYCLE = {"start", "progress", "failure", "retry", "cancel", "complete"}


def main() -> int:
    if not CONTRACT.exists():
        print(f"ERROR: missing {CONTRACT}", file=sys.stderr)
        return 1

    text = CONTRACT.read_text(encoding="utf-8")
    errors: list[str] = []

    for required, message in REQUIRED_TEXT.items():
        if required not in text:
            errors.append(message)

    for state in sorted(REQUIRED_LIFECYCLE):
        if f"- {state}" not in text:
            errors.append(f"missing operation event lifecycle state: {state}")

    for dimension in ("externalSite", "connector", "authDomain", "thirdPartyAutomation"):
        if f"- {dimension}" not in text:
            errors.append(f"missing trust boundary dimension: {dimension}")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print("BearBrowser workspace operation plane contract verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
