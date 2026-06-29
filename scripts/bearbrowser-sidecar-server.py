#!/usr/bin/env python3
"""Localhost-only BearBrowser sidecar server with token-gated resolution actions."""
from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import secrets
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HOST = "127.0.0.1"
DEFAULT_PORT = 8765
SCRIPT_DIR = Path(__file__).resolve().parent


def support_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser"


def default_events() -> Path:
    return support_dir() / "provenance" / "events.jsonl"


def default_actions() -> Path:
    return support_dir() / "policy" / "actions.jsonl"


def default_memory() -> Path:
    return support_dir() / "memory" / "candidates.jsonl"


def default_summaries() -> Path:
    return support_dir() / "summaries" / "page-summaries.jsonl"


def default_comparisons() -> Path:
    return support_dir() / "comparisons" / "page-comparisons.jsonl"


def default_receipts() -> Path:
    return support_dir() / "receipts" / "receipts.jsonl"


def default_hold_queue() -> Path:
    return support_dir() / "policy" / "hold-queue.jsonl"


def token_path() -> Path:
    return support_dir() / "sidecar" / "server-token"


def get_token() -> str:
    path = token_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        token = path.read_text(encoding="utf-8").strip()
        if token:
            return token
    token = secrets.token_urlsafe(32)
    path.write_text(token, encoding="utf-8")
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return token


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for raw in handle:
            raw = raw.strip()
            if not raw:
                continue
            try:
                item = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                records.append(item)
    return records


def latest_receipts(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return the most recent version of each receipt (by receiptId)."""
    by_id: dict[str, dict[str, Any]] = {}
    for record in records:
        rid = record.get("receiptId", "")
        if rid:
            by_id[rid] = record
    return list(by_id.values())


def unresolved_actions(actions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved = set()
    for action in actions:
        target = action.get("target", {})
        if isinstance(target, dict) and target.get("resolvedFromActionId"):
            resolved.add(str(target["resolvedFromActionId"]))
    return [
        action for action in actions
        if action.get("decision", {}).get("state") == "hold"
        and str(action.get("actionId")) not in resolved
    ]


def pending_memory(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved = {str(record.get("resolvesMemoryId")) for record in records if record.get("resolvesMemoryId")}
    return [
        record for record in records
        if record.get("state") == "candidate"
        and str(record.get("memoryId")) not in resolved
    ]


def esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


def tool_script(name: str) -> list[str]:
    mapping = {
        "bearbrowser-resolve-action": "bearbrowser-resolve-action.py",
        "bearbrowser-memory-candidate": "bearbrowser-memory-candidate.py",
    }
    script = SCRIPT_DIR / mapping[name]
    return [sys.executable, str(script)]


def run_command(command: list[str]) -> tuple[int, str]:
    try:
        proc = subprocess.run(command, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return proc.returncode, proc.stdout[-4000:]
    except Exception as exc:  # pragma: no cover
        return 99, str(exc)


def render_table_actions(actions: list[dict[str, Any]], token: str) -> str:
    if not actions:
        return '<p class="muted">No held policy actions.</p>'
    rows = []
    for action in reversed(actions):
        target = action.get("target", {}) if isinstance(action.get("target"), dict) else {}
        risk = action.get("risk", {}) if isinstance(action.get("risk"), dict) else {}
        aid = esc(action.get("actionId", ""))
        rows.append(
            "<tr>"
            f"<td><code>{aid}</code></td>"
            f"<td>{esc(action.get('actionType', ''))}</td>"
            f"<td>{esc(target.get('kind', ''))}:{esc(target.get('label', ''))}</td>"
            f"<td>{esc(risk.get('level', ''))}</td>"
            "<td class='actions'>"
            f"<form method='post' action='/action/allow?token={esc(token)}'><input type='hidden' name='action_id' value='{aid}'><button>Allow</button></form>"
            f"<form method='post' action='/action/deny?token={esc(token)}'><input type='hidden' name='action_id' value='{aid}'><button class='danger'>Deny</button></form>"
            "</td></tr>"
        )
    return "<table><thead><tr><th>Action ID</th><th>Type</th><th>Target</th><th>Risk</th><th>Resolve</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


def render_table_memory(records: list[dict[str, Any]], token: str) -> str:
    if not records:
        return '<p class="muted">No pending memory candidates.</p>'
    rows = []
    for record in reversed(records):
        source = record.get("source", {}) if isinstance(record.get("source"), dict) else {}
        classification = record.get("classification", {}) if isinstance(record.get("classification"), dict) else {}
        mid = esc(record.get("memoryId", ""))
        text = str(record.get("text", ""))
        if len(text) > 180:
            text = text[:177] + "..."
        rows.append(
            "<tr>"
            f"<td><code>{mid}</code></td>"
            f"<td>{esc(source.get('kind', ''))}:{esc(source.get('label', ''))}</td>"
            f"<td>{esc(classification.get('payloadClass', ''))}</td>"
            f"<td>{esc(text)}</td>"
            "<td class='actions'>"
            f"<form method='post' action='/memory/commit?token={esc(token)}'><input type='hidden' name='memory_id' value='{mid}'><button>Commit</button></form>"
            f"<form method='post' action='/memory/reject?token={esc(token)}'><input type='hidden' name='memory_id' value='{mid}'><button class='danger'>Reject</button></form>"
            "</td></tr>"
        )
    return "<table><thead><tr><th>Memory ID</th><th>Source</th><th>Class</th><th>Text</th><th>Resolve</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


def render_table_summaries(records: list[dict[str, Any]]) -> str:
    if not records:
        return '<p class="muted">No page summaries yet.</p>'
    rows = []
    for record in reversed(records[-10:]):
        source = record.get("source", {}) if isinstance(record.get("source"), dict) else {}
        classification = record.get("classification", {}) if isinstance(record.get("classification"), dict) else {}
        policy = record.get("policy", {}) if isinstance(record.get("policy"), dict) else {}
        summary = record.get("summary", {}) if isinstance(record.get("summary"), dict) else {}
        text = str(summary.get("summaryText", ""))
        if len(text) > 220:
            text = text[:217] + "..."
        rows.append(
            "<tr>"
            f"<td>{esc(record.get('timestamp', ''))}</td>"
            f"<td>{esc(source.get('kind', ''))}:{esc(source.get('label', ''))}</td>"
            f"<td>{esc(classification.get('payloadClass', ''))}</td>"
            f"<td>{esc(policy.get('decision', ''))}</td>"
            f"<td>{esc(text)}</td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Time</th><th>Source</th><th>Class</th><th>Decision</th><th>Summary</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


def render_table_comparisons(records: list[dict[str, Any]]) -> str:
    if not records:
        return '<p class="muted">No page comparisons yet.</p>'
    rows = []
    for record in reversed(records[-10:]):
        left = record.get("left", {}) if isinstance(record.get("left"), dict) else {}
        right = record.get("right", {}) if isinstance(record.get("right"), dict) else {}
        classification = record.get("classification", {}) if isinstance(record.get("classification"), dict) else {}
        policy = record.get("policy", {}) if isinstance(record.get("policy"), dict) else {}
        comparison = record.get("comparison", {}) if isinstance(record.get("comparison"), dict) else {}
        text = str(comparison.get("summaryText", ""))
        if len(text) > 220:
            text = text[:217] + "..."
        rows.append(
            "<tr>"
            f"<td>{esc(record.get('timestamp', ''))}</td>"
            f"<td>{esc(left.get('label', 'left'))} ↔ {esc(right.get('label', 'right'))}</td>"
            f"<td>{esc(classification.get('payloadClass', ''))}</td>"
            f"<td>{esc(policy.get('decision', ''))}</td>"
            f"<td>{esc(text)}</td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Time</th><th>Inputs</th><th>Class</th><th>Decision</th><th>Comparison</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


STATUS_BADGE_COLORS = {
    "active": "#2ecc71",
    "ended": "#888888",
    "revoked": "#e74c3c",
    "failed": "#e67e22",
    "denied": "#c0392b",
    "orphaned": "#7f8c8d",
}


def status_badge(status: str) -> str:
    color = STATUS_BADGE_COLORS.get(status, "#555")
    return (
        f"<span style='display:inline-block;padding:3px 9px;border-radius:999px;"
        f"background:{color};color:#fff;font-size:12px;font-weight:700'>"
        f"{esc(status)}</span>"
    )


def render_table_receipts(receipts: list[dict[str, Any]]) -> str:
    if not receipts:
        return '<p class="muted">No automation receipts yet.</p>'
    active = [r for r in receipts if r.get("status") == "active"]
    others = [r for r in receipts if r.get("status") != "active"]
    ordered = list(reversed(active)) + list(reversed(others))
    rows = []
    for receipt in ordered:
        rid = esc(receipt.get("receiptId", ""))
        short_id = rid.split(":")[-1][:12] if ":" in rid else rid[:12]
        rows.append(
            "<tr>"
            f"<td><code title='{rid}'>{short_id}…</code></td>"
            f"<td>{esc(receipt.get('transport', ''))}</td>"
            f"<td>{esc(receipt.get('ownerRef', '').split(':')[-1])}</td>"
            f"<td>{esc(receipt.get('displayName', ''))}</td>"
            f"<td>{esc(receipt.get('capturedAt', ''))}</td>"
            f"<td>{status_badge(receipt.get('status', ''))}</td>"
            "</tr>"
        )
    return (
        "<table><thead><tr>"
        "<th>Receipt</th><th>Transport</th><th>Owner</th><th>Session</th><th>Created</th><th>Status</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
    )


def render_table_hold_queue(records: list[dict[str, Any]], token: str) -> str:
    if not records:
        return '<p class="muted">No held policy decisions.</p>'
    rows = []
    for record in reversed(records):
        decision_id = esc(record.get("decisionId", record.get("decision_id", "")))
        rows.append(
            "<tr>"
            f"<td><code>{decision_id}</code></td>"
            f"<td>{esc(record.get('actionType', record.get('action_type', '')))}</td>"
            f"<td>{esc(record.get('reason', ''))}</td>"
            f"<td>{esc(record.get('requestedAt', record.get('timestamp', '')))}</td>"
            "<td class='actions'>"
            f"<form method='post' action='/resolve?token={esc(token)}'>"
            f"<input type='hidden' name='decision_id' value='{decision_id}'>"
            f"<input type='hidden' name='resolution' value='allow'>"
            f"<button>Allow</button></form>"
            f"<form method='post' action='/resolve?token={esc(token)}'>"
            f"<input type='hidden' name='decision_id' value='{decision_id}'>"
            f"<input type='hidden' name='resolution' value='deny'>"
            f"<button class='danger'>Deny</button></form>"
            "</td></tr>"
        )
    return (
        "<table><thead><tr>"
        "<th>Decision ID</th><th>Action</th><th>Reason</th><th>Requested</th><th>Resolve</th>"
        "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
    )


def render_page(token: str, message: str = "") -> str:
    events = read_jsonl(default_events())
    actions = unresolved_actions(read_jsonl(default_actions()))
    memory = pending_memory(read_jsonl(default_memory()))
    summaries = read_jsonl(default_summaries())
    comparisons = read_jsonl(default_comparisons())
    receipts = latest_receipts(read_jsonl(default_receipts()))
    hold_queue = read_jsonl(default_hold_queue())

    active_sessions = [r for r in receipts if r.get("status") == "active"]
    now_str = dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    notice = f"<div class='notice'>{esc(message)}</div>" if message else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="10">
<title>BearBrowser Governance</title>
<style>
:root{{color-scheme:dark;--bg:#1a1a1a;--panel:#242424;--line:#3a3a3a;--text:#f0f0f0;--muted:#999;--gold:#f6d28b;--danger:#ff9d9d;--green:#2ecc71;--gray:#888;}}
*{{box-sizing:border-box}}
body{{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:var(--bg);color:var(--text)}}
header{{background:#111;border-bottom:1px solid var(--line);padding:16px 28px;display:flex;align-items:center;justify-content:space-between}}
header h1{{margin:0;font-size:22px;font-weight:700;color:var(--gold)}}
header .timestamp{{color:var(--muted);font-size:13px}}
main{{max-width:1240px;margin:0 auto;padding:28px 24px 80px}}
p{{color:var(--muted)}}
.pill{{display:inline-block;padding:4px 10px;border-radius:999px;background:#2a2a2a;color:var(--gold);font-weight:700;font-size:12px;border:1px solid var(--line)}}
.grid{{display:grid;grid-template-columns:repeat(6,1fr);gap:14px;margin:20px 0}}
.card{{border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:18px;}}
.metric{{font-size:32px;font-weight:800;color:var(--gold)}}
section{{margin-top:20px}}
section.card h2{{margin:0 0 14px;font-size:16px;color:var(--gold);font-weight:700}}
table{{width:100%;border-collapse:collapse}}
th,td{{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);vertical-align:top}}
th{{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em}}
tr:last-child td{{border-bottom:none}}
button{{background:#2f2f2f;color:var(--text);border:1px solid var(--line);border-radius:8px;padding:6px 11px;font-weight:700;cursor:pointer}}
button:hover{{background:#3a3a3a}}
button.danger{{color:var(--danger);border-color:#5a2a2a}}
button.danger:hover{{background:#3a2020}}
.actions{{display:flex;gap:8px;flex-wrap:wrap}}
.muted{{color:var(--muted)}}
.notice{{margin-top:16px;padding:12px 16px;border:1px solid var(--line);border-radius:10px;background:#2a2510;color:var(--gold)}}
code{{color:var(--gold);font-size:13px}}
@media(max-width:960px){{.grid{{grid-template-columns:1fr 1fr 1fr}}}}
@media(max-width:560px){{.grid{{grid-template-columns:1fr 1fr}}}}
</style>
</head>
<body>
<header>
  <div>
    <span class="pill">local sidecar</span>
    <h1>BearBrowser Governance</h1>
  </div>
  <div class="timestamp">{esc(now_str)}</div>
</header>
<main>
{notice}
<div class="grid">
<div class="card"><div class="metric">{len(active_sessions)}</div><p>active sessions</p></div>
<div class="card"><div class="metric">{len(receipts)}</div><p>total receipts</p></div>
<div class="card"><div class="metric">{len(hold_queue)}</div><p>hold queue</p></div>
<div class="card"><div class="metric">{len(events)}</div><p>provenance events</p></div>
<div class="card"><div class="metric">{len(actions)}</div><p>held actions</p></div>
<div class="card"><div class="metric">{len(memory)}</div><p>pending memory</p></div>
</div>

<section class="card">
  <h2>Automation Sessions (Receipts)</h2>
  {render_table_receipts(receipts)}
</section>

<section class="card">
  <h2>Hold Queue</h2>
  {render_table_hold_queue(hold_queue, token)}
</section>

<section class="card">
  <h2>Held Policy Actions</h2>
  {render_table_actions(actions, token)}
</section>

<section class="card">
  <h2>Pending Memory Candidates</h2>
  {render_table_memory(memory, token)}
</section>

<section class="card">
  <h2>Recent Events</h2>
  <p class="muted">{len(events)} provenance event(s) recorded.</p>
</section>

<section class="card">
  <h2>Recent Page Comparisons</h2>
  {render_table_comparisons(comparisons)}
</section>

<section class="card">
  <h2>Recent Page Summaries</h2>
  {render_table_summaries(summaries)}
</section>
</main>
</body>
</html>"""


def resolve_hold_decision(decision_id: str, resolution: str) -> tuple[int, str]:
    """Resolve a held policy decision. Calls bearbrowser-resolve-action.py if it exists,
    otherwise appends a resolution record directly to hold-queue.jsonl."""
    resolve_script = SCRIPT_DIR / "bearbrowser-resolve-action.py"
    if resolve_script.exists():
        return run_command([
            sys.executable, str(resolve_script),
            "--action-id", decision_id,
            "--decision", resolution,
            "--actor-type", "human",
            "--actor-id", "sidecar",
            "--reason", f"{resolution.capitalize()}d from interactive sidecar.",
        ])

    # Fallback: append a resolution record directly to hold-queue.jsonl
    import datetime as _dt
    hold_queue_path = default_hold_queue()
    hold_queue_path.parent.mkdir(parents=True, exist_ok=True)
    record = {
        "schemaVersion": "bearbrowser.hold_queue_resolution.v1",
        "decisionId": decision_id,
        "resolution": resolution,
        "resolvedBy": "sidecar",
        "resolvedAt": _dt.datetime.now(_dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "reason": f"{resolution.capitalize()}d from interactive sidecar.",
    }
    try:
        with hold_queue_path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        return 0, f"Resolution appended to {hold_queue_path}"
    except OSError as exc:
        return 1, f"Failed to append resolution: {exc}"


class Handler(BaseHTTPRequestHandler):
    server_version = "BearBrowserSidecar/0.1"

    def token_ok(self) -> bool:
        parsed = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        return q.get("token", [""])[0] == self.server.token  # type: ignore[attr-defined]

    def send_html(self, html_text: str, status: int = 200) -> None:
        data = html_text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_json(self, payload: Any, status: int = 200) -> None:
        data = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def read_form(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        parsed = urllib.parse.parse_qs(raw)
        return {key: values[0] for key, values in parsed.items() if values}

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)

        # Read-only JSON API endpoints (no token required — localhost only, read-only)
        if parsed.path == "/api/receipts":
            receipts = latest_receipts(read_jsonl(default_receipts()))
            self.send_json({"receipts": receipts, "count": len(receipts)})
            return

        if parsed.path == "/api/hold-queue":
            records = read_jsonl(default_hold_queue())
            self.send_json({"holdQueue": records, "count": len(records)})
            return

        if not self.token_ok():
            self.send_html("<h1>BearBrowser sidecar denied</h1><p>Invalid token.</p>", 403)
            return
        self.send_html(render_page(self.server.token))  # type: ignore[attr-defined]

    def do_POST(self) -> None:  # noqa: N802
        if not self.token_ok():
            self.send_html("<h1>BearBrowser sidecar denied</h1><p>Invalid token.</p>", 403)
            return
        parsed = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(parsed.query)
        form = self.read_form()
        message = "No action taken."

        if parsed.path == "/action/allow":
            action_id = form.get("action_id", "")
            code, out = run_command(tool_script("bearbrowser-resolve-action") + ["--action-id", action_id, "--decision", "allow", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Allowed from interactive sidecar."])
            message = "Allowed held action." if code == 0 else f"Allow failed: {out}"
        elif parsed.path == "/action/deny":
            action_id = form.get("action_id", "")
            code, out = run_command(tool_script("bearbrowser-resolve-action") + ["--action-id", action_id, "--decision", "deny", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Denied from interactive sidecar."])
            message = "Denied held action." if code == 0 else f"Deny failed: {out}"
        elif parsed.path == "/memory/commit":
            memory_id = form.get("memory_id", "")
            code, out = run_command(tool_script("bearbrowser-memory-candidate") + ["resolve", "--memory-id", memory_id, "--decision", "commit", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Committed from interactive sidecar."])
            message = "Committed memory candidate." if code == 0 else f"Commit failed: {out}"
        elif parsed.path == "/memory/reject":
            memory_id = form.get("memory_id", "")
            code, out = run_command(tool_script("bearbrowser-memory-candidate") + ["resolve", "--memory-id", memory_id, "--decision", "reject", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Rejected from interactive sidecar."])
            message = "Rejected memory candidate." if code == 0 else f"Reject failed: {out}"
        elif parsed.path == "/resolve":
            # Support both query-string and form-body parameters for decision_id and resolution
            decision_id = (
                q.get("decision_id", [""])[0]
                or form.get("decision_id", "")
            )
            resolution = (
                q.get("resolution", [""])[0]
                or form.get("resolution", "")
            )
            if not decision_id:
                message = "ERROR: decision_id is required."
            elif resolution not in {"allow", "deny"}:
                message = f"ERROR: resolution must be allow or deny, got {resolution!r}."
            else:
                code, out = resolve_hold_decision(decision_id, resolution)
                message = f"{resolution.capitalize()}d decision {decision_id}." if code == 0 else f"Resolve failed: {out}"

        self.send_html(render_page(self.server.token, message))  # type: ignore[attr-defined]

    def log_message(self, fmt: str, *args: Any) -> None:
        return


class Server(ThreadingHTTPServer):
    token: str


def main() -> int:
    parser = argparse.ArgumentParser(description="Run BearBrowser interactive local sidecar server")
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--print-url", action="store_true")
    args = parser.parse_args()

    if args.host not in {"127.0.0.1", "localhost"}:
        raise SystemExit("ERROR: sidecar server must bind to localhost")

    token = get_token()
    server = Server((args.host, args.port), Handler)
    server.token = token
    url = f"http://127.0.0.1:{args.port}/?token={urllib.parse.quote(token)}"
    if args.print_url:
        print(url)
        return 0
    print(f"BearBrowser interactive sidecar: {url}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
