#!/usr/bin/env python3
"""Emit local BearBrowser provenance events as redacted JSONL."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import secrets
import sys
from pathlib import Path
from typing import Any

EVENT_TYPES = {
    "app.launch",
    "app.close",
    "navigation.requested",
    "navigation.committed",
    "tab.created",
    "tab.closed",
    "page.shared_with_agent",
    "credential.requested",
    "credential.granted",
    "credential.denied",
    "autofill.requested",
    "download.requested",
    "upload.requested",
    "clipboard.read_requested",
    "clipboard.write_requested",
    "extension.capability_used",
    "automation.observed",
    "automation.action_requested",
    "automation.action_approved",
    "automation.action_denied",
    "memory.candidate_created",
    "memory.committed",
    "memory.rejected",
    "policy.decision",
    "runtime.health",
    "browser.session.start",
    "browser.capture.create",
    "browser.download.create",
    "browser.upload.create",
    "browser.automation.run",
    "browser.diagnostics.export_redacted",
}

SURFACES = {
    "native-shell",
    "gecko-runtime",
    "automation-wrapper",
    "terminal-browser",
    "packaging",
    "credential-broker",
    "policy",
    "agent-sidecar",
}

PROFILES = {"human-secure", "agent-runtime", "bootstrap", "unknown"}
ACTOR_TYPES = {"human", "agent", "system", "automation"}
DECISIONS = {"allow", "deny", "hold", "observe", "not_applicable"}
POLICY_MODES = {"local-default", "policyfabric", "manual", "not_applicable"}
PAYLOAD_CLASSES = {"public", "metadata", "sensitive-metadata", "secret-blocked"}
SECRET_KEYS = {
    "password",
    "passphrase",
    "secret",
    "token",
    "credential",
    "cookie",
    "authorization",
    "api_key",
    "apikey",
    "private_key",
    "payment",
    "card",
    "cvv",
}


def now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def default_log_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def sanitize(value: Any) -> Any:
    if isinstance(value, dict):
        cleaned: dict[str, Any] = {}
        for key, inner in value.items():
            key_str = str(key)
            lowered = key_str.lower().replace("-", "_")
            if any(secret in lowered for secret in SECRET_KEYS):
                cleaned[key_str] = "<REDACTED>"
            else:
                cleaned[key_str] = sanitize(inner)
        return cleaned
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    return value


def has_secret_key(value: Any) -> bool:
    if isinstance(value, dict):
        for key, inner in value.items():
            lowered = str(key).lower().replace("-", "_")
            if any(secret in lowered for secret in SECRET_KEYS):
                return True
            if has_secret_key(inner):
                return True
    elif isinstance(value, list):
        return any(has_secret_key(item) for item in value)
    return False


def parse_payload(raw: str | None) -> dict[str, Any]:
    if not raw:
        return {}
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"ERROR: --payload must be valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise SystemExit("ERROR: --payload must decode to a JSON object")
    return data


def validate_choice(name: str, value: str, allowed: set[str]) -> None:
    if value not in allowed:
        allowed_s = ", ".join(sorted(allowed))
        raise SystemExit(f"ERROR: invalid {name}: {value}. Allowed: {allowed_s}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit a BearBrowser local provenance event")
    parser.add_argument("--event-type", required=True)
    parser.add_argument("--surface", default="native-shell")
    parser.add_argument("--profile", default="bootstrap")
    parser.add_argument("--actor-type", default="system")
    parser.add_argument("--actor-id", default=os.environ.get("USER", "local-user"))
    parser.add_argument("--actor-display-name", default="")
    parser.add_argument("--decision", default="not_applicable")
    parser.add_argument("--decision-id", default="")
    parser.add_argument("--policy-mode", default="not_applicable")
    parser.add_argument("--policy-reason", default="")
    parser.add_argument("--payload", default="{}", help="JSON object payload. Secret-looking keys are redacted.")
    parser.add_argument("--payload-class", default="metadata")
    parser.add_argument("--session-id", default="")
    parser.add_argument("--out", default=str(default_log_path()))
    args = parser.parse_args()

    validate_choice("event-type", args.event_type, EVENT_TYPES)
    validate_choice("surface", args.surface, SURFACES)
    validate_choice("profile", args.profile, PROFILES)
    validate_choice("actor-type", args.actor_type, ACTOR_TYPES)
    validate_choice("decision", args.decision, DECISIONS)
    validate_choice("policy-mode", args.policy_mode, POLICY_MODES)
    validate_choice("payload-class", args.payload_class, PAYLOAD_CLASSES)

    payload = parse_payload(args.payload)
    secret_present = has_secret_key(payload)
    cleaned_payload = sanitize(payload)
    decision_id = args.decision_id or f"local-{secrets.token_hex(8)}"

    event = {
        "schemaVersion": "bearbrowser.provenance.v1",
        "eventId": f"evt-{secrets.token_hex(16)}",
        "timestamp": now(),
        "product": "BearBrowser",
        "surface": args.surface,
        "profile": args.profile,
        "eventType": args.event_type,
        "actor": {
            "type": args.actor_type,
            "id": args.actor_id,
        },
        "policy": {
            "decision": args.decision,
            "decisionId": decision_id,
            "mode": args.policy_mode,
        },
        "redaction": {
            "secretValuesPresent": bool(secret_present),
            "secretValuesLogged": False,
            "payloadClass": "secret-blocked" if secret_present else args.payload_class,
        },
        "payload": cleaned_payload,
    }
    if args.actor_display_name:
        event["actor"]["displayName"] = args.actor_display_name
    if args.session_id:
        event["sessionId"] = args.session_id
    if args.policy_reason:
        event["policy"]["reason"] = args.policy_reason

    out = Path(args.out).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")

    print(f"BearBrowser provenance event written: {out}")
    print(json.dumps(event, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
