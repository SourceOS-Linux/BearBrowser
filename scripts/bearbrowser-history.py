#!/usr/bin/env python3
"""BearHistory dry-run contract surface for BearBrowser.

This command intentionally does not read browser profiles, cookies, credentials,
history databases, downloads, or captures. It emits deterministic JSON plans for
policy review and downstream contract integration.
"""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from typing import Any


DEFAULT_POLICY_REF = "urn:srcos:bearhistory-sync-policy:default-local-first-v1"
DEFAULT_SERVICE_REF = "urn:srcos:local-first-service:bearhistoryd"
DEFAULT_WORKROOM = "urn:srcos:workroom:professional-intelligence-demo"
DEFAULT_AGENT_PROFILE = "urn:srcos:profile:agent-runtime"


def now() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def print_json(value: dict[str, Any]) -> int:
    print(json.dumps(value, indent=2, sort_keys=True))
    return 0


def policy_explain(profile: str) -> dict[str, Any]:
    if profile not in {"human-secure", "agent-runtime"}:
        raise SystemExit("profile must be human-secure or agent-runtime")

    human_secure = profile == "human-secure"
    export_to_ops_history = "deny" if human_secure else "policy-gated"
    lanes = [
        {
            "lane": "save",
            "priority": "maintenance" if human_secure else "normal",
            "idleDelaySeconds": 90 if human_secure else 30,
            "cadence": [{"count": 1, "intervalSeconds": 86400}]
            if human_secure
            else [{"count": 50, "intervalSeconds": 60}, {"count": 10, "intervalSeconds": 300}],
            "requiresPolicyDecision": True,
        },
        {
            "lane": "redaction",
            "priority": "critical",
            "idleDelaySeconds": 6,
            "cadence": [{"count": 20, "intervalSeconds": 5}],
            "requiresPolicyDecision": True,
        },
    ]
    if not human_secure:
        lanes.insert(
            1,
            {
                "lane": "export",
                "priority": "normal",
                "idleDelaySeconds": 30,
                "cadence": [{"count": 20, "intervalSeconds": 180}],
                "requiresPolicyDecision": True,
            },
        )

    return {
        "planKind": "bearhistory-policy-explain",
        "dryRun": True,
        "generatedAt": now(),
        "profileClass": profile,
        "policyRef": DEFAULT_POLICY_REF,
        "serviceManifestRef": DEFAULT_SERVICE_REF,
        "exportToOpsHistory": export_to_ops_history,
        "syncWindowSeconds": 1209600 if human_secure else 604800,
        "payloadCapChars": 100000 if human_secure else 50000,
        "profileBoundary": {
            "credentialsExportAllowed": False,
            "cookiesExportAllowed": False,
            "ambientSessionExportAllowed": False,
            "humanProfileExportAllowed": False,
            "agentRuntimeExportAllowed": not human_secure,
        },
        "lanes": lanes,
        "network": {
            "offlineBehavior": "queue-local",
            "meteredAllowed": False,
            "batteryAllowed": True,
            "transferDirection": "bidirectional",
        },
        "nonGoals": [
            "no browser database reads",
            "no credential access",
            "no cookie access",
            "no live export",
        ],
    }


def export_explain(session: str, profile: str) -> dict[str, Any]:
    if profile not in {"human-secure", "agent-runtime"}:
        raise SystemExit("profile must be human-secure or agent-runtime")

    allowed = profile == "agent-runtime"
    return {
        "planKind": "bearhistory-export-explain",
        "dryRun": True,
        "generatedAt": now(),
        "sessionRef": session if session.startswith("urn:") else f"urn:srcos:browser-session:{session}",
        "profileClass": profile,
        "outcome": "metadata-only" if allowed else "deny",
        "opsHistoryEventRef": f"urn:srcos:ops-history-event:bearbrowser-{session}-metadata-dry-run",
        "policyDecisionRefs": [
            "urn:srcos:policy-decision:ops-history-browser-event-export-demo-0001"
        ],
        "agentRegistryRefs": ["urn:srcos:agent-grant:ops-history-browser-demo"] if allowed else [],
        "payloadMode": "metadata-only" if allowed else "redacted",
        "profileBoundary": {
            "humanProfileExportAllowed": False,
            "credentialMaterialIncluded": False,
            "cookieMaterialIncluded": False,
            "ambientSessionMaterialIncluded": False,
        },
        "targetScope": {
            "workroomRef": DEFAULT_WORKROOM,
            "profileRef": DEFAULT_AGENT_PROFILE if allowed else "urn:srcos:profile:human-secure",
        },
    }


def redactions_pending() -> dict[str, Any]:
    return {
        "planKind": "bearhistory-redactions-pending",
        "dryRun": True,
        "generatedAt": now(),
        "pending": [],
        "policy": {
            "redactionPriority": "critical",
            "targetPropagationSeconds": 30,
            "invalidateOpsHistoryExports": True,
            "invalidateContextPacks": True,
            "invalidateMemoryWritebacks": True,
        },
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bearbrowser-history",
        description="BearHistory dry-run policy and export-plan surface.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    policy = subparsers.add_parser("policy", help="Explain BearHistory profile policy.")
    policy_sub = policy.add_subparsers(dest="policy_command", required=True)
    explain_policy = policy_sub.add_parser("explain")
    explain_policy.add_argument("--profile", default="agent-runtime")
    explain_policy.add_argument("--dry-run", action="store_true", default=True)

    export = subparsers.add_parser("export", help="Explain BearHistory export posture.")
    export_sub = export.add_subparsers(dest="export_command", required=True)
    explain_export = export_sub.add_parser("explain")
    explain_export.add_argument("--session", default="demo")
    explain_export.add_argument("--profile", default="agent-runtime")
    explain_export.add_argument("--dry-run", action="store_true", default=True)

    redactions = subparsers.add_parser("redactions", help="Show pending BearHistory redaction posture.")
    redactions.add_argument("--dry-run", action="store_true", default=True)

    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if not getattr(args, "dry_run", True):
        raise SystemExit("BearHistory commands are dry-run only in this implementation slice")
    if args.command == "policy" and args.policy_command == "explain":
        return print_json(policy_explain(args.profile))
    if args.command == "export" and args.export_command == "explain":
        return print_json(export_explain(args.session, args.profile))
    if args.command == "redactions":
        return print_json(redactions_pending())
    raise SystemExit("unknown BearHistory command")


if __name__ == "__main__":
    raise SystemExit(main())
