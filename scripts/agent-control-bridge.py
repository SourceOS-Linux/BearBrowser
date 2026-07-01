#!/usr/bin/env python3
"""
BearBrowser Agent Control Bridge — the ENFORCING governed agent surface.
========================================================================
The control bridge an agent (e.g. TurtleTerm's copilot) calls to drive
BearBrowser, where EVERY action passes through policy enforcement BEFORE it
can execute. This is the containment Gartner's directive names and that no
shipping AI browser (Comet/Atlas/Dia/Copilot) provides: inspect agent intent,
ALLOW specific actions while RESTRICTING others — block rogue/injected actions
at decision time, not log them after the fact.

What this implements (see docs/agent-control-bridge.md + policy/bearbrowser-contract.yaml):

  evaluate_action(action, params, approval_token) -> Decision
    allowed     -> PERMIT  + attest a browser.<action> ReasoningEvent
    gated       -> PERMIT only if a valid approval_token for THIS action is
                   present; otherwise DENY + attest browser.<action> (deny)
    prohibited  -> DENY unconditionally (no approval path) + attest
                   browser.policy.violation
  policyConditions re-classify a base action from planner params
    (a click flagged as submit-form -> gated; a fill into a credential/
     payment/gov-id field -> prohibited).

The enforcement + attestation layer is PURE: it works and is testable WITHOUT a
live browser binary (dry/enforce-only mode). `connect()` would drive the real
binary over WebDriver-BiDi (loopback + token); if no browser is reachable the
bridge still evaluates + emits, so containment is provable on any machine.

Evidence is emitted as spec-conformant ReasoningEvents (sourceos-spec v2),
identical in shape to TurtleTerm's turtle-agentd reasoning-event family, into
SOURCEOS_REASONING_EVIDENCE (default ~/.local/state/sourceos/reasoning/). These
receipts are sealable by agentplane like the rest of the fabric.

CLI:
  agent-control-bridge --action navigate --url example.com            # allowed -> permit
  agent-control-bridge --action submit-form                           # gated   -> deny (no token)
  agent-control-bridge --action submit-form --approval-token <t>      # gated   -> permit
  agent-control-bridge --action enter-credentials                     # prohibited -> deny + violation
  agent-control-bridge --action click --param intent=submit-form      # reclassified -> gated -> deny
  agent-control-bridge --action fill-form-field --param fieldType=password  # reclassified -> prohibited
  add --json for machine output.

Exit codes:  0 permit   3 deny   1 error
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import socket
import sys
import uuid
from pathlib import Path
from typing import Any, Optional

# ---------------------------------------------------------------------------
# Live WebDriver-BiDi transport (loaded from lib/bidi_transport.py). This is the
# wire UNDER the enforcement gate — it is only ever reached after
# evaluate_action returns permit. Import is guarded so enforce-only mode works
# even if the module (or its optional websocket dep) is unavailable.
# ---------------------------------------------------------------------------
_BIDI: Any = None
try:
    _repo_root = Path(__file__).resolve().parent.parent
    if str(_repo_root) not in sys.path:
        sys.path.insert(0, str(_repo_root))
    from lib import bidi_transport as _BIDI  # type: ignore
except Exception:
    _BIDI = None

# ---------------------------------------------------------------------------
# Constants — mirror the sourceos-spec reasoning family + turtle-agentd shapes
# ---------------------------------------------------------------------------

REASONING_SPEC_VERSION = "2.0.0"
PRODUCT = "BearBrowser"
DEFAULT_POLICY_REF = "urn:srcos:policy:bearbrowser-agent-runtime"

# trustLevel / traceLevel enums (sourceos-spec)
TRUST_CONTROL = "trusted-control-input"      # agent control intent
TRACE_WORKSPACE_SAFE = "workspace-safe"

VALID_CLASSES = ("allowed", "gated", "prohibited")


# ---------------------------------------------------------------------------
# Time / id helpers
# ---------------------------------------------------------------------------

def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _run_id() -> str:
    return f"urn:srcos:reasoning-run:{uuid.uuid4().hex}"


def _event_id() -> str:
    return f"urn:srcos:reasoning-event:{uuid.uuid4().hex}"


def _receipt_id() -> str:
    return f"urn:srcos:receipt:reasoning:{uuid.uuid4().hex}"


def _approval_id() -> str:
    return f"urn:srcos:approval:{uuid.uuid4().hex}"


def _run_hex(run_id: str) -> str:
    return run_id.rsplit(":", 1)[-1] or uuid.uuid4().hex


# ---------------------------------------------------------------------------
# Evidence sink — mirror the reasoning-evidence convention
# ---------------------------------------------------------------------------

def reasoning_evidence_root() -> Path:
    return Path(os.environ.get(
        "SOURCEOS_REASONING_EVIDENCE",
        str(Path.home() / ".local" / "state" / "sourceos" / "reasoning"),
    ))


def reasoning_event_stream_path() -> Path:
    return reasoning_evidence_root() / "reasoning-events.ndjson"


# ---------------------------------------------------------------------------
# Minimal YAML loader for the contract (stdlib-only fallback).
# Tries PyYAML first; if absent, parses the specific structure of
# bearbrowser-contract.yaml including inline-flow {..} maps and [..] lists used
# by the agentActionContract block.
# ---------------------------------------------------------------------------

def _parse_flow(text: str) -> Any:
    """Parse a JSON-ish inline-flow scalar/map/list (the {..}/[..] used in the contract).

    The contract's inline values are valid JSON once bare keys are quoted, but the
    keys here are already quoted strings (jsonlogic style). We coerce the common
    cases: JSON object/array via json.loads, else bare scalar.
    """
    text = text.strip()
    if not text:
        return None
    if text[0] in "{[":
        try:
            return json.loads(text)
        except Exception:
            pass
    # bare scalar
    low = text.lower()
    if low in ("true", "false"):
        return low == "true"
    # strip wrapping quotes
    if len(text) >= 2 and text[0] in "\"'" and text[-1] == text[0]:
        return text[1:-1]
    return text


def _load_contract(path: Path) -> dict[str, Any]:
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore
        data = yaml.safe_load(text)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return _parse_contract_yaml(text)


def _parse_contract_yaml(text: str) -> dict[str, Any]:
    """Cleaner indent-stack parser that decides list-vs-map by the child's first
    non-blank line (peek). Handles inline-flow values via _parse_flow."""
    root: dict[str, Any] = {}
    # stack: (indent, container, kind)
    stack: list[tuple[int, Any, str]] = [(-1, root, "map")]
    raw_lines = [ln for ln in text.splitlines()]

    # Pre-clean comments (guarding inline-flow braces)
    cleaned: list[str] = []
    for raw in raw_lines:
        if "#" in raw and "{" not in raw and "[" not in raw:
            raw = raw.split("#", 1)[0]
        cleaned.append(raw)

    def next_content_indent(i: int) -> tuple[int, str]:
        for j in range(i + 1, len(cleaned)):
            s = cleaned[j]
            if not s.strip():
                continue
            return len(s) - len(s.lstrip()), s.strip()
        return -1, ""

    i = 0
    while i < len(cleaned):
        raw = cleaned[i]
        if not raw.strip():
            i += 1
            continue
        indent = len(raw) - len(raw.lstrip())
        content = raw.strip()

        # pop to parent
        while len(stack) > 1 and stack[-1][0] >= indent:
            stack.pop()
        container, kind = stack[-1][1], stack[-1][2]

        if content.startswith("- "):
            item = content[2:].strip()
            if kind != "list":
                i += 1
                continue
            if ":" in item and item[0] not in "{[":
                m: dict[str, Any] = {}
                container.append(m)
                key, _, val = item.partition(":")
                key, val = key.strip(), val.strip()
                if val:
                    m[key] = _parse_flow(val)
                    # subsequent keys of this map are at indent+2
                    stack.append((indent + 1, m, "map"))
                else:
                    ci, _ = next_content_indent(i)
                    child: Any = [] if False else {}
                    m[key] = child
                    stack.append((indent + 1, m, "map"))
                    stack.append((indent + 2, child, "map"))
            else:
                container.append(_parse_flow(item))
            i += 1
            continue

        if ":" not in content:
            i += 1
            continue
        key, _, val = content.partition(":")
        key, val = key.strip(), val.strip()
        if kind != "map":
            i += 1
            continue
        if val:
            container[key] = _parse_flow(val)
        else:
            ci, cfirst = next_content_indent(i)
            if ci > indent and cfirst.startswith("- "):
                child_l: list[Any] = []
                container[key] = child_l
                stack.append((indent, child_l, "list"))
            else:
                child_m: dict[str, Any] = {}
                container[key] = child_m
                stack.append((indent, child_m, "map"))
        i += 1

    return root


def resolve_contract_path() -> Path:
    env_home = os.environ.get("BEARBROWSER_HOME", "")
    if env_home:
        c = Path(env_home) / "policy" / "bearbrowser-contract.yaml"
        if c.exists():
            return c
    repo_root = Path(__file__).resolve().parent.parent
    c = repo_root / "policy" / "bearbrowser-contract.yaml"
    if c.exists():
        return c
    raise FileNotFoundError(
        "Cannot locate bearbrowser-contract.yaml. Set BEARBROWSER_HOME or place it "
        f"at {c}"
    )


# ---------------------------------------------------------------------------
# Policy model
# ---------------------------------------------------------------------------

class Policy:
    """In-memory action->class map + replayClass/eventType + policyConditions,
    loaded from policy/bearbrowser-contract.yaml spec.agentActionContract."""

    def __init__(self, contract: dict[str, Any]):
        spec = contract.get("spec", {}) if isinstance(contract, dict) else {}
        aac = spec.get("agentActionContract", {}) or {}
        self.policy_ref: str = aac.get("policyRef", DEFAULT_POLICY_REF)
        self.default_decision: str = aac.get("defaultDecision", "deny")

        self.action_class: dict[str, str] = {}
        self.replay_class: dict[str, str] = {}
        self.event_type: dict[str, str] = {}

        classes = aac.get("actionClasses", {}) or {}
        for cls in VALID_CLASSES:
            for entry in (classes.get(cls) or []):
                if not isinstance(entry, dict):
                    continue
                name = entry.get("action")
                if not name:
                    continue
                self.action_class[name] = cls
                if entry.get("replayClass"):
                    self.replay_class[name] = entry["replayClass"]
                self.event_type[name] = entry.get("eventType", f"browser.{name}")

        self.conditions: list[dict[str, Any]] = [
            c for c in (aac.get("policyConditions") or []) if isinstance(c, dict)
        ]

    # -- jsonlogic-style predicate evaluation (the minimal subset the contract uses) --
    @staticmethod
    def _eval_logic(rule: Any, data: dict[str, Any]) -> Any:
        if not isinstance(rule, dict):
            return rule
        if len(rule) != 1:
            return rule
        op, args = next(iter(rule.items()))
        if op == "var":
            key = args if isinstance(args, str) else (args[0] if isinstance(args, list) and args else "")
            return data.get(key)
        if isinstance(args, list):
            vals = [Policy._eval_logic(a, data) for a in args]
        else:
            vals = [Policy._eval_logic(args, data)]
        if op == "==":
            return len(vals) >= 2 and vals[0] == vals[1]
        if op == "!=":
            return len(vals) >= 2 and vals[0] != vals[1]
        if op == "in":
            return len(vals) >= 2 and vals[0] in (vals[1] or [])
        if op == "and":
            return all(vals)
        if op == "or":
            return any(vals)
        return False

    def classify(self, action: str, params: dict[str, Any]) -> tuple[str, str, Optional[str]]:
        """Return (effective_action, effective_class, matched_condition_id).

        Applies policyConditions in order (first match wins) to re-classify the
        base action based on planner-supplied params.
        """
        params = params or {}
        base_class = self.action_class.get(action, self.default_decision_class())
        eff_action, eff_class, cond_id = action, base_class, None
        for cond in self.conditions:
            if cond.get("appliesTo") != action:
                continue
            when = cond.get("when")
            if when is None or self._eval_logic(when, params):
                eff_class = cond.get("reclassifyTo", eff_class)
                eff_action = cond.get("as", eff_action)
                cond_id = cond.get("id")
                break
        return eff_action, eff_class, cond_id

    def default_decision_class(self) -> str:
        # An action absent from the contract is denied -> treat as prohibited so it
        # is blocked unconditionally (fail-closed).
        return "prohibited"

    def replay_class_for(self, action: str) -> str:
        return self.replay_class.get(action, "non-replayable-side-effect")

    def event_type_for(self, action: str, eff_class: str) -> str:
        if eff_class == "prohibited":
            return "browser.policy.violation"
        return self.event_type.get(action, f"browser.{action}")


# ---------------------------------------------------------------------------
# Decision + evidence
# ---------------------------------------------------------------------------

class Decision:
    def __init__(self, *, action: str, requested_action: str, decision: str,
                 action_class: str, reason: str, event: dict[str, Any],
                 condition_id: Optional[str], replay_class: str):
        self.action = action                  # effective action after reclassification
        self.requested_action = requested_action
        self.decision = decision              # "permit" | "deny"
        self.action_class = action_class      # allowed | gated | prohibited
        self.reason = reason
        self.event = event                    # the attested ReasoningEvent
        self.condition_id = condition_id
        self.replay_class = replay_class

    @property
    def permitted(self) -> bool:
        return self.decision == "permit"

    def to_dict(self) -> dict[str, Any]:
        return {
            "requestedAction": self.requested_action,
            "effectiveAction": self.action,
            "actionClass": self.action_class,
            "decision": self.decision,
            "reason": self.reason,
            "reclassifiedBy": self.condition_id,
            "replayClass": self.replay_class,
            "attestedEvent": self.event,
        }


class ControlBridge:
    """The enforcing bridge. Pure enforcement + attestation; no live browser needed."""

    def __init__(self, policy: Policy, run: Optional[dict[str, Any]] = None,
                 emit: bool = True, agent: str = "turtle-copilot"):
        self.policy = policy
        self.emit = emit
        self.agent = agent
        self.run = run or self._open_run("BearBrowser governed agent session")
        self.connected = False
        self.bidi_url: Optional[str] = None
        self._weakest_replay = "exact"
        self._client: Any = None  # live BidiClient once connect() succeeds

    # -- session run (mirrors turtle-agentd._open_reasoning_run) --
    def _open_run(self, task_summary: str) -> dict[str, Any]:
        run_id = _run_id()
        workspace = os.environ.get("SOURCEOS_WORKSPACE", "default")
        return {
            "id": run_id,
            "type": "ReasoningRun",
            "specVersion": REASONING_SPEC_VERSION,
            "status": "running",
            "task": {
                "id": f"urn:srcos:reasoning-task:{_run_hex(run_id)}",
                "title": task_summary[:200],
            },
            "agentRef": f"urn:srcos:agent:{self.agent}",
            "workspaceRef": f"urn:srcos:workspace:{workspace}",
            "safeTrace": {
                "mode": "operational-trace-only",
                "rawPrivateReasoning": "not-collected",
                "eventCount": 0,
            },
            "eventRefs": [],
            "artifactRefs": [],
            "startedAt": utc_now(),
        }

    # -- attest one ReasoningEvent (mirrors turtle-agentd._emit_reasoning_event) --
    def _attest(self, event_type: str, summary: str, extra: dict[str, Any]) -> dict[str, Any]:
        event = {
            "id": _event_id(),
            "type": "ReasoningEvent",
            "specVersion": REASONING_SPEC_VERSION,
            "runRef": self.run["id"],
            "eventType": event_type,
            # SAFE summary only — the action + decision, never raw page content.
            "summary": summary[:500],
            "traceLevel": TRACE_WORKSPACE_SAFE,
            "trustLevel": TRUST_CONTROL,
            "capturedAt": utc_now(),
        }
        for k, v in (extra or {}).items():
            if k not in event:
                event[k] = v
        if self.emit:
            try:
                path = reasoning_event_stream_path()
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps(event) + "\n")
            except Exception:
                pass
        self.run.setdefault("eventRefs", []).append(event["id"])
        st = self.run.get("safeTrace")
        if isinstance(st, dict):
            st["eventCount"] = len(self.run["eventRefs"])
        return event

    # -- THE CORE ENFORCEMENT --
    def evaluate_action(self, action: str, params: Optional[dict[str, Any]] = None,
                        approval_token: Optional[str] = None) -> Decision:
        params = params or {}
        eff_action, eff_class, cond_id = self.policy.classify(action, params)
        replay = self.policy.replay_class_for(eff_action)
        note = f" (reclassified {action}->{eff_action} by {cond_id})" if cond_id else ""
        # track weakest replay class across the session (for the receipt)
        _order = {"exact": 0, "best-effort": 1, "evidence-only": 2, "non-replayable-side-effect": 3}
        if _order.get(replay, 3) > _order.get(self._weakest_replay, 0):
            self._weakest_replay = replay

        if eff_class == "allowed":
            summary = f"{eff_action} permitted{note}"
            event = self._attest(
                self.policy.event_type_for(eff_action, eff_class), summary,
                {"decision": "permit", "policyRef": self.policy.policyRef_safe(),
                 "actionClass": "allowed"},
            )
            return Decision(action=eff_action, requested_action=action, decision="permit",
                            action_class="allowed", reason="allowed action class",
                            event=event, condition_id=cond_id, replay_class=replay)

        if eff_class == "gated":
            if approval_token and self._token_valid(approval_token, eff_action):
                approval_ref = _approval_id()
                summary = f"gated action '{eff_action}' approved by operator{note}"
                event = self._attest(
                    self.policy.event_type_for(eff_action, eff_class), summary,
                    {"decision": "permit", "policyRef": self.policy.policyRef_safe(),
                     "actionClass": "gated", "approvalTokenRef": approval_ref},
                )
                return Decision(action=eff_action, requested_action=action, decision="permit",
                                action_class="gated", reason="gated: valid approval token present",
                                event=event, condition_id=cond_id, replay_class=replay)
            # gated, no/invalid token -> DENY (blocked at decision time)
            summary = f"gated action '{eff_action}' DENIED: requires approval{note}"
            event = self._attest(
                self.policy.event_type_for(eff_action, eff_class), summary,
                {"decision": "deny", "policyRef": self.policy.policyRef_safe(),
                 "actionClass": "gated"},
            )
            return Decision(action=eff_action, requested_action=action, decision="deny",
                            action_class="gated", reason="gated: requires approval",
                            event=event, condition_id=cond_id, replay_class=replay)

        # prohibited -> DENY unconditionally, no approval path, emit violation
        summary = f"PROHIBITED action '{eff_action}' BLOCKED at decision time{note}"
        event = self._attest(
            "browser.policy.violation", summary,
            {"decision": "deny", "policyRef": self.policy.policyRef_safe(),
             "actionClass": "prohibited"},
        )
        return Decision(action=eff_action, requested_action=action, decision="deny",
                        action_class="prohibited",
                        reason="prohibited: denied unconditionally (no approval path)",
                        event=event, condition_id=cond_id, replay_class=replay)

    @staticmethod
    def _token_valid(token: str, action: str) -> bool:
        """A valid per-action approval token. In production this is a signed,
        single-use grant scoped to THIS action issued by the operator via the
        approval surface. Here: accept a non-empty token; if it encodes a scope
        (`action:...`) it must match the action being approved."""
        if not token:
            return False
        if token.startswith("action:"):
            scoped = token.split(":", 1)[1].split("#", 1)[0]
            return scoped == action
        return True

    # -- live transport (graceful) --
    def connect(self, bidi_url: str, token: str, timeout: float = 0.5) -> bool:
        """Attach to the live BearBrowser binary over WebDriver-BiDi (loopback +
        session token). Opens the WebSocket and completes the BiDi `session.new`
        handshake. Returns True iff a control endpoint is reachable AND the
        handshake succeeds. The bridge ENFORCES regardless — if unreachable it
        runs in dry/enforce-only mode so containment is provable on any machine.

        A non-loopback bidi_url is REFUSED (no socket is opened).
        """
        self.bidi_url = bidi_url
        host, port = self._parse_loopback(bidi_url)
        if host is None:
            self.connected = False
            return False
        if host not in ("127.0.0.1", "localhost", "::1"):
            # the spec mandates loopback-only; refuse non-loopback control endpoints
            self.connected = False
            self._client = None
            return False

        # Prefer the real BiDi client (WebSocket + session.new). If the transport
        # module is unavailable, or the browser is not reachable, fall back to a
        # bare TCP probe so callers still get a truthful reachable/not signal —
        # but without a live client we stay enforce-only (no commands sent).
        if _BIDI is not None:
            try:
                self._client = _BIDI.BidiClient(bidi_url, token, timeout=timeout)
                self.connected = True
                return True
            except Exception:
                self._client = None
                self.connected = False
                return False

        try:
            with socket.create_connection((host, port), timeout=timeout):
                self.connected = True
        except OSError:
            self.connected = False
        self._client = None
        return self.connected

    @staticmethod
    def _parse_loopback(url: str) -> tuple[Optional[str], int]:
        try:
            from urllib.parse import urlparse
            u = urlparse(url if "://" in url else f"ws://{url}")
            return (u.hostname or None), (u.port or 0)
        except Exception:
            return None, 0

    # -- THE REAL ENTRY POINT: gate FIRST, then (only on permit) touch the wire --
    def dispatch(self, action: str, params: Optional[dict[str, Any]] = None,
                 approval_token: Optional[str] = None) -> Decision:
        """Evaluate the action against policy FIRST. If denied, attest and return
        WITHOUT emitting any BiDi command — the browser is never touched. If
        permitted, map the action to its BiDi command and send it over the live
        client (or, with no browser connected, stay enforce-only "would-permit").

        The enforcement gate sits strictly BEFORE transport: a denied/injected
        action can NEVER put a frame on the wire. This is the containment
        boundary, and it holds at the transport edge, not just in policy.
        """
        params = params or {}
        decision = self.evaluate_action(action, params, approval_token)

        # GATE: a non-permitted decision emits NO BiDi command. Full stop.
        if not decision.permitted:
            return decision

        # Permitted. If we have no live client, stay enforce-only: the decision
        # stands (would-permit) but nothing goes on a wire that doesn't exist.
        if not self.connected or self._client is None or _BIDI is None:
            return decision

        # Map the PERMITTED action to a BiDi command. Gated/prohibited map to
        # None even here (defense in depth); permitted allowed-class actions map
        # to a real command.
        mapped = _BIDI.build_bidi_command(decision.action, params)
        if mapped is None:
            # No command for this action (e.g. a permitted action with no wire
            # form). Nothing to send; the permit + attestation already stand.
            return decision

        method, bidi_params = mapped
        try:
            result = self._client.send_command(method, bidi_params)
            summary = _BIDI.summarize_result(method, result)
            self._attest(
                "browser.transport.dispatched",
                f"{decision.action} dispatched over BiDi: {summary}",
                {"decision": "permit", "policyRef": self.policy.policyRef_safe(),
                 "actionClass": decision.action_class, "bidiMethod": method,
                 "transport": "live-bidi"},
            )
        except Exception as exc:  # transport error — record, do not crash the gate
            self._attest(
                "browser.transport.error",
                f"{decision.action} BiDi dispatch failed: {type(exc).__name__}",
                {"decision": "permit", "policyRef": self.policy.policyRef_safe(),
                 "actionClass": decision.action_class, "bidiMethod": method,
                 "transport": "live-bidi", "error": type(exc).__name__},
            )
        return decision

    def close(self, status: str = "completed") -> dict[str, Any]:
        """Close the run with a ReasoningReceipt. replayClass = weakest of all
        actions in the session."""
        if self._client is not None:
            try:
                self._client.close()
            except Exception:
                pass
            self._client = None
            self.connected = False
        run_hex = _run_hex(self.run["id"])
        digest = hashlib.sha256(
            "\n".join(self.run.get("eventRefs", [])).encode("utf-8", errors="replace")
        ).hexdigest()
        receipt = {
            "id": _receipt_id(),
            "type": "ReasoningReceipt",
            "specVersion": REASONING_SPEC_VERSION,
            "runRef": self.run["id"],
            "taskRef": self.run.get("task", {}).get("id", f"urn:srcos:task:{run_hex}"),
            "status": status,
            "traceHash": "sha256:" + digest,
            "replayClass": getattr(self, "_weakest_replay", "best-effort"),
            "capturedAt": utc_now(),
        }
        if self.emit:
            try:
                run_dir = reasoning_evidence_root() / run_hex
                run_dir.mkdir(parents=True, exist_ok=True)
                self.run["status"] = status
                self.run["completedAt"] = utc_now()
                (run_dir / "run.json").write_text(json.dumps(self.run, indent=2), encoding="utf-8")
                (run_dir / "receipt.json").write_text(json.dumps(receipt, indent=2), encoding="utf-8")
            except Exception:
                pass
        return receipt


# patch Policy with a safe accessor used above
def _policy_ref_safe(self: Policy) -> str:  # noqa: D401
    return getattr(self, "policy_ref", DEFAULT_POLICY_REF)


Policy.policyRef_safe = _policy_ref_safe  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Public convenience
# ---------------------------------------------------------------------------

def load_policy() -> Policy:
    return Policy(_load_contract(resolve_contract_path()))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="BearBrowser ENFORCING agent control bridge — blocks gated/prohibited "
                    "(incl. injected) actions at decision time + attests every one.")
    parser.add_argument("--action", required=True, help="Agent action to evaluate")
    parser.add_argument("--url", default="", help="Target URL (for navigate, informational)")
    parser.add_argument("--param", action="append", default=[], metavar="KEY=VALUE",
                        help="Planner-supplied action param (e.g. intent=submit-form, "
                             "fieldType=password). May re-classify the action.")
    parser.add_argument("--approval-token", default=None,
                        help="Per-action approval token for gated actions "
                             "(e.g. action:submit-form).")
    parser.add_argument("--bidi-url", default="", help="WebDriver-BiDi loopback control URL")
    parser.add_argument("--bidi-token", default="", help="Per-session BiDi bearer token")
    parser.add_argument("--no-emit", action="store_true",
                        help="Evaluate without writing evidence (decision is still pure)")
    parser.add_argument("--json", action="store_true", help="Machine-readable JSON output")
    args = parser.parse_args(argv)

    try:
        policy = load_policy()
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    params: dict[str, Any] = {}
    for pair in args.param:
        if "=" in pair:
            k, _, v = pair.partition("=")
            params[k.strip()] = v.strip()
    if args.url:
        params.setdefault("url", args.url)

    bridge = ControlBridge(policy, emit=not args.no_emit)

    # graceful live transport: try to attach, but enforce regardless
    transport = "dry/enforce-only"
    connected = False
    if args.bidi_url:
        connected = bridge.connect(args.bidi_url, args.bidi_token)
        transport = "live-bidi" if connected else "no browser -> enforce-only"

    # dispatch() gates FIRST, then drives the wire only on permit; when no
    # browser is connected it degrades to enforce-only automatically.
    decision = bridge.dispatch(args.action, params, args.approval_token)

    out = decision.to_dict()
    out["transport"] = transport
    out["runRef"] = bridge.run["id"]

    if args.json:
        print(json.dumps(out, indent=2))
    else:
        verb = "PERMIT" if decision.permitted else "DENY"
        print(f"[{verb}] {decision.requested_action} "
              f"(class={decision.action_class}) — {decision.reason}")
        if decision.condition_id:
            print(f"  reclassified -> {decision.action} by policyCondition '{decision.condition_id}'")
        ev = decision.event
        print(f"  attested: {ev['eventType']}  {ev['id']}")
        print(f"  trustLevel={ev['trustLevel']} traceLevel={ev['traceLevel']} "
              f"capturedAt={ev['capturedAt']}")
        print(f"  transport: {transport}")

    return 0 if decision.permitted else 3


if __name__ == "__main__":
    sys.exit(main())
