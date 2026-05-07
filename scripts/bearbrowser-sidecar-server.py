#!/usr/bin/env python3
"""Localhost-only BearBrowser sidecar server with token-gated resolution actions."""
from __future__ import annotations

import argparse
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


def support_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser"


def default_events() -> Path:
    return support_dir() / "provenance" / "events.jsonl"


def default_actions() -> Path:
    return support_dir() / "policy" / "actions.jsonl"


def default_memory() -> Path:
    return support_dir() / "memory" / "candidates.jsonl"


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


def render_page(token: str, message: str = "") -> str:
    events = read_jsonl(default_events())
    actions = unresolved_actions(read_jsonl(default_actions()))
    memory = pending_memory(read_jsonl(default_memory()))
    notice = f"<div class='notice'>{esc(message)}</div>" if message else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BearBrowser Interactive Sidecar</title>
<style>
:root{{color-scheme:dark;--bg:#17130f;--panel:#252018;--line:#5f432f;--text:#f5eee5;--muted:#cbbbaa;--gold:#f6d28b;--danger:#ff9d9d;}}
*{{box-sizing:border-box}}body{{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:radial-gradient(circle at 22% 10%,#39281c 0,#17130f 42%,#0f0d0b 100%);color:var(--text)}}main{{max-width:1180px;margin:0 auto;padding:42px 24px 80px}}h1{{font-size:42px;margin:0 0 8px}}p{{color:var(--muted)}}.pill{{display:inline-block;padding:6px 10px;border-radius:999px;background:#3a3027;color:var(--gold);font-weight:700}}.grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:26px 0}}.card{{border:1px solid var(--line);border-radius:22px;background:rgba(37,32,24,.94);padding:20px;box-shadow:0 18px 50px rgba(0,0,0,.22)}}.metric{{font-size:36px;font-weight:800;color:var(--gold)}}section{{margin-top:22px}}table{{width:100%;border-collapse:collapse}}th,td{{text-align:left;padding:11px 12px;border-bottom:1px solid #3c3026;vertical-align:top}}th{{color:var(--gold);font-size:13px;text-transform:uppercase;letter-spacing:.04em}}button{{background:#4d3929;color:var(--text);border:1px solid var(--line);border-radius:10px;padding:7px 11px;font-weight:700;cursor:pointer}}button.danger{{color:var(--danger)}}.actions{{display:flex;gap:8px;flex-wrap:wrap}}.muted{{color:var(--muted)}}.notice{{margin-top:18px;padding:14px 16px;border:1px solid var(--line);border-radius:16px;background:#2f281f;color:var(--gold)}}code{{color:var(--gold)}}@media(max-width:760px){{.grid{{grid-template-columns:1fr}}}}
</style>
</head>
<body>
<main>
<span class="pill">interactive local sidecar</span>
<h1>BearBrowser Governance Queue</h1>
<p>Local-only queue for held actions and pending memory candidates. Resolution writes auditable local policy and provenance records.</p>
{notice}
<div class="grid">
<div class="card"><div class="metric">{len(events)}</div><p>provenance events</p></div>
<div class="card"><div class="metric">{len(actions)}</div><p>held actions</p></div>
<div class="card"><div class="metric">{len(memory)}</div><p>pending memory</p></div>
</div>
<section class="card"><h2>Held Policy Actions</h2>{render_table_actions(actions, token)}</section>
<section class="card"><h2>Pending Memory Candidates</h2>{render_table_memory(memory, token)}</section>
</main>
</body>
</html>"""


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

    def read_form(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        parsed = urllib.parse.parse_qs(raw)
        return {key: values[0] for key, values in parsed.items() if values}

    def do_GET(self) -> None:  # noqa: N802
        if not self.token_ok():
            self.send_html("<h1>BearBrowser sidecar denied</h1><p>Invalid token.</p>", 403)
            return
        self.send_html(render_page(self.server.token))  # type: ignore[attr-defined]

    def do_POST(self) -> None:  # noqa: N802
        if not self.token_ok():
            self.send_html("<h1>BearBrowser sidecar denied</h1><p>Invalid token.</p>", 403)
            return
        parsed = urllib.parse.urlparse(self.path)
        form = self.read_form()
        message = "No action taken."
        if parsed.path == "/action/allow":
            action_id = form.get("action_id", "")
            code, out = run_command(["bearbrowser-resolve-action", "--action-id", action_id, "--decision", "allow", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Allowed from interactive sidecar."])
            message = "Allowed held action." if code == 0 else f"Allow failed: {out}"
        elif parsed.path == "/action/deny":
            action_id = form.get("action_id", "")
            code, out = run_command(["bearbrowser-resolve-action", "--action-id", action_id, "--decision", "deny", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Denied from interactive sidecar."])
            message = "Denied held action." if code == 0 else f"Deny failed: {out}"
        elif parsed.path == "/memory/commit":
            memory_id = form.get("memory_id", "")
            code, out = run_command(["bearbrowser-memory-candidate", "resolve", "--memory-id", memory_id, "--decision", "commit", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Committed from interactive sidecar."])
            message = "Committed memory candidate." if code == 0 else f"Commit failed: {out}"
        elif parsed.path == "/memory/reject":
            memory_id = form.get("memory_id", "")
            code, out = run_command(["bearbrowser-memory-candidate", "resolve", "--memory-id", memory_id, "--decision", "reject", "--actor-type", "human", "--actor-id", "sidecar", "--reason", "Rejected from interactive sidecar."])
            message = "Rejected memory candidate." if code == 0 else f"Reject failed: {out}"
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
