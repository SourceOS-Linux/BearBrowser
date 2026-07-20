#!/usr/bin/env python3
"""BearBrowser Receipts — the cockpit's trust surface (loopback).

Every governed decision the enforcing bridge makes — across ALL three surfaces —
is attested to one evidence stream (agent-control-bridge.py writes safe-trace
ReasoningEvents to reasoning-events.ndjson):

    browser.*   the governed browser        (agentActionContract)
    iot.*       the smart-home / IoT estate (iotActionContract)
    agent.*     the cockpit's local agent   (agentMachineActionContract)

This service reads that one stream and serves it as a live, verifiable ledger — the
Receipts surface of docs/cockpit-spec.md §2. It is the trust differentiator: a
running, signed log of every action the user's agents proposed and exactly what
policy did about it — the thing Gartner says agentic browsers cannot show. Nothing
here reaches off-device; it only reads the local evidence stream and serves loopback.

    GET /health                          liveness + stream location
    GET /receipts?surface=&decision=&violations=&limit=&since=
                                         parsed receipts, newest first
    GET /receipts/summary                aggregate counts per surface + verdicts
    GET /receipts/stream                 Server-Sent Events live tail (new receipts)

    BEARBROWSER_RECEIPTS_PORT            listen port (default 8092)
    SOURCEOS_REASONING_EVIDENCE         evidence root (default ~/.local/state/sourceos/reasoning)
"""
import json
import os
import sys
import time
import threading
import pathlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT = int(os.environ.get("BEARBROWSER_RECEIPTS_PORT", "8092"))


def evidence_root() -> pathlib.Path:
    env = os.environ.get("SOURCEOS_REASONING_EVIDENCE")
    if env:
        return pathlib.Path(env).expanduser()
    return pathlib.Path.home() / ".local" / "state" / "sourceos" / "reasoning"


def stream_path() -> pathlib.Path:
    return evidence_root() / "reasoning-events.ndjson"


def surface_of(event_type: str) -> str:
    head = (event_type or "").split(".", 1)[0]
    return head if head in ("browser", "iot", "agent") else "other"


def to_receipt(ev: dict) -> dict:
    """Project a raw ReasoningEvent into a receipt row for the surface."""
    et = ev.get("eventType", "")
    decision = ev.get("decision")  # merged from the bridge's extra: permit|deny
    is_violation = et.endswith("policy.violation")
    if decision is None:
        decision = "deny" if is_violation else "permit"
    # action = the event type minus the surface prefix (browser.navigate -> navigate)
    action = et.split(".", 1)[1] if "." in et else et
    return {
        "id": ev.get("id"),
        "at": ev.get("capturedAt"),
        "surface": surface_of(et),
        "eventType": et,
        "action": action,
        "decision": decision,
        "class": ev.get("actionClass"),
        "violation": is_violation,
        "reason": ev.get("summary"),
        "runRef": ev.get("runRef"),
        "policyRef": ev.get("policyRef"),
        "approvalTokenRef": ev.get("approvalTokenRef"),
        "trustLevel": ev.get("trustLevel"),
        "traceLevel": ev.get("traceLevel"),
    }


def read_events():
    """Yield parsed events from the stream (skips malformed lines)."""
    p = stream_path()
    if not p.exists():
        return
    with p.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


class ReceiptsHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        # Loopback-only page (cockpit) reads this; permissive CORS is safe (no secrets,
        # read-only, loopback bind). The bind — not CORS — is the security boundary.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)

        if u.path == "/health":
            p = stream_path()
            return self._json({"ok": True, "stream": str(p), "exists": p.exists()})

        if u.path == "/receipts":
            receipts = [to_receipt(e) for e in read_events()]
            # filters
            surf = (q.get("surface", [None])[0])
            dec = (q.get("decision", [None])[0])
            since = (q.get("since", [None])[0])
            only_viol = q.get("violations", ["0"])[0] in ("1", "true")
            if surf:
                receipts = [r for r in receipts if r["surface"] == surf]
            if dec:
                receipts = [r for r in receipts if r["decision"] == dec]
            if only_viol:
                receipts = [r for r in receipts if r["violation"]]
            if since:
                receipts = [r for r in receipts if (r["at"] or "") > since]
            receipts.reverse()  # newest first
            try:
                limit = int(q.get("limit", ["200"])[0])
            except ValueError:
                limit = 200
            return self._json({"count": len(receipts), "receipts": receipts[:limit]})

        if u.path == "/receipts/summary":
            surfaces, verdicts, violations = {}, {"permit": 0, "deny": 0}, 0
            classes = {"allowed": 0, "gated": 0, "prohibited": 0}
            total = 0
            for e in read_events():
                r = to_receipt(e)
                total += 1
                surfaces[r["surface"]] = surfaces.get(r["surface"], 0) + 1
                verdicts[r["decision"]] = verdicts.get(r["decision"], 0) + 1
                if r["class"] in classes:
                    classes[r["class"]] += 1
                if r["violation"]:
                    violations += 1
            return self._json({
                "total": total, "bySurface": surfaces, "byDecision": verdicts,
                "byClass": classes, "violations": violations,
            })

        if u.path == "/receipts/stream":
            return self._sse_tail()

        return self._json({"error": "not-found"}, status=404)

    def _sse_tail(self):
        """Server-Sent Events: emit new receipts as they are appended."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        p = stream_path()
        # start at end of file; stream appended lines
        pos = p.stat().st_size if p.exists() else 0
        try:
            while True:
                if p.exists() and p.stat().st_size > pos:
                    with p.open("r", encoding="utf-8", errors="replace") as fh:
                        fh.seek(pos)
                        for line in fh:
                            line = line.strip()
                            if not line:
                                continue
                            try:
                                ev = json.loads(line)
                            except json.JSONDecodeError:
                                continue
                            payload = json.dumps(to_receipt(ev))
                            self.wfile.write(f"data: {payload}\n\n".encode())
                            self.wfile.flush()
                        pos = fh.tell()
                else:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                time.sleep(1.0)
        except (BrokenPipeError, ConnectionResetError):
            return

    def log_message(self, fmt, *args):
        sys.stderr.write("[receipts] " + (fmt % args) + "\n")


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), ReceiptsHandler)
    print(f"[receipts] serving the trust ledger on 127.0.0.1:{PORT} "
          f"(stream: {stream_path()})", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()


if __name__ == "__main__":
    main()
