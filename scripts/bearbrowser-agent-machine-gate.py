#!/usr/bin/env python3
"""BearBrowser agent-machine governance gate — Lane 4 of the cockpit composition.

The cockpit's local agent (the bundled Noetica agent-machine loopback sidecar) is
powerful: it runs pipelines, mutates graphs, writes knowledge, and — if unguarded —
could reach the host shell/filesystem. This gate puts BearBrowser's enforcing
policy engine in front of it, so EVERY agent action is classified BEFORE execution
by the same `agent-control-bridge.py` that governs the browser and the IoT estate:

    cockpit (client-vue)  ──►  THIS gate (127.0.0.1:GATE_PORT)
                                 │  classify (agent-control-bridge --surface agent-machine)
                                 │    allowed    → forward
                                 │    gated      → forward ONLY with a valid approval token
                                 │    prohibited → 403, blocked at decision time + attested
                                 ▼
                          agent-machine sidecar (127.0.0.1:UPSTREAM_PORT)

This is the Gartner "inspect agent intent + enforce per-action policy" control,
applied to the cockpit's own agent. A prompt-injected `execute-shell` is DENIED and
attested (agent.policy.violation), never merely logged after. Loopback-only; it
does not edit the Noetica engine (it sits in front of it).

    NOETICA_AM_UPSTREAM_PORT   real agent-machine port (default 8091)
    BEARBROWSER_AM_GATE_PORT   gate listen port the cockpit targets (default 8080)

The cockpit passes user-intent via headers the UI sets on DIRECT interaction and
the agent planner cannot forge:
    X-Cockpit-Actor: user|agent      X-Cockpit-User-Gesture: true|false
    X-Cockpit-Approval-Token: <per-action token for gated actions>
"""
import json
import os
import sys
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import pathlib

# ── Load the enforcing bridge as a library (in-process; no per-request subprocess) ──
_HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("acb", _HERE / "agent-control-bridge.py")
_acb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_acb)

GATE_PORT = int(os.environ.get("BEARBROWSER_AM_GATE_PORT", "8080"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = int(os.environ.get("NOETICA_AM_UPSTREAM_PORT", "8091"))
UPSTREAM = f"http://{UPSTREAM_HOST}:{UPSTREAM_PORT}"

# ── Route → governance action mapping ───────────────────────────────────────────
# Security-first: reads are allowed, known mutations are gated, host-reaching /
# destructive patterns are prohibited, and ANYTHING UNRECOGNIZED fails closed
# (mapped to a prohibited action → denied). The action names correspond to
# spec.agentMachineActionContract in policy/bearbrowser-contract.yaml.
#
# Each entry: (method_predicate, path_substring, action). First match wins.
_RULES = [
    # ── prohibited: host-reaching / destructive (denied unless a cockpit user gesture) ──
    (lambda m: True, "/shell",        "execute-shell"),
    (lambda m: True, "/exec",         "execute-shell"),
    (lambda m: True, "/terminal",     "execute-shell"),
    (lambda m: True, "/command",      "execute-shell"),
    (lambda m: True, "/fs/read",      "read-host-filesystem"),
    (lambda m: True, "/fs/write",     "write-host-filesystem"),
    (lambda m: True, "/file/write",   "write-host-filesystem"),
    (lambda m: True, "/credential",   "read-credentials"),
    (lambda m: True, "/secret",       "read-credentials"),
    (lambda m: True, "/egress",       "disable-egress-guard"),
    (lambda m: True, "/offline",      "disable-egress-guard"),
    (lambda m: True, "/governance",   "disable-governance"),
    # ── gated: mutating / executing ──
    (lambda m: m != "GET", "/pipeline", "run-pipeline"),
    (lambda m: m != "GET", "/run",      "run-pipeline"),
    (lambda m: m != "GET", "/devspace", "devspace-command"),
    (lambda m: m != "GET", "/install",  "install-package"),
    (lambda m: m != "GET", "/fetch",    "network-fetch"),
    (lambda m: m != "GET", "/proxy",    "network-fetch"),
    (lambda m: m != "GET", "/knowledge", "write-knowledge"),
    (lambda m: m != "GET", "/graph",     "mutate-graph"),
    # ── allowed: reads + chat ──
    (lambda m: True, "/chat",       "chat-completion"),
    (lambda m: True, "/completion", "chat-completion"),
    (lambda m: True, "/status",     "query-status"),
    (lambda m: True, "/health",     "query-status"),
    (lambda m: True, "/models",     "list-models"),
    (lambda m: m == "GET", "/knowledge", "read-knowledge"),
    (lambda m: m == "GET", "/graph",     "read-graph"),
]


def classify_action(method: str, path: str) -> str:
    p = path.lower()
    for pred, needle, action in _RULES:
        if needle in p and pred(method):
            return action
    # GET to an unrecognized route → treat as a read (allowed). Any other method to
    # an unrecognized route → fail closed (an unmapped prohibited action → denied).
    if method == "GET":
        return "query-status"
    return "execute-shell"   # unknown mutation → the strongest prohibited → deny


# One bridge/session for the gate process. evaluate_action is pure + attests.
_policy = _acb.load_policy("agent-machine")


def _params_from_headers(headers) -> dict:
    actor = (headers.get("X-Cockpit-Actor") or "agent").strip().lower()
    gesture = (headers.get("X-Cockpit-User-Gesture") or "false").strip().lower() == "true"
    return {"actor": actor, "userGesture": gesture}


class GateHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _handle(self):
        action = classify_action(self.command, self.path)
        params = _params_from_headers(self.headers)
        token = self.headers.get("X-Cockpit-Approval-Token")
        bridge = _acb.ControlBridge(_policy, emit=True, agent="cockpit-agent-machine")
        decision = bridge.evaluate_action(action, params, token)

        if not decision.permitted:
            # Blocked at decision time. The bridge already attested the event.
            body = json.dumps({
                "error": "blocked-by-policy",
                "action": decision.action,
                "class": decision.action_class,
                "reason": decision.reason,
                "attestedEvent": decision.event.get("id"),
            }).encode()
            self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            self.log_message("DENY %s %s -> %s/%s", self.command, self.path,
                             decision.action, decision.action_class)
            return

        # Permitted → forward to the real agent-machine sidecar.
        self._forward()

    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(UPSTREAM + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length"):
                req.add_header(k, v)
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:  # upstream unreachable
            msg = json.dumps({"error": "agent-machine-unreachable", "detail": str(e)}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(msg)))
            self.end_headers()
            self.wfile.write(msg)

    # Route every method through the gate.
    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle

    def log_message(self, fmt, *args):
        sys.stderr.write("[am-gate] " + (fmt % args) + "\n")


def main():
    # Loopback-only. Refuse to serve anything but 127.0.0.1.
    server = ThreadingHTTPServer(("127.0.0.1", GATE_PORT), GateHandler)
    print(f"[am-gate] governing agent-machine: cockpit -> 127.0.0.1:{GATE_PORT} "
          f"-> {UPSTREAM} (surface=agent-machine)", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
