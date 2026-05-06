#!/usr/bin/env python3
"""Render BearBrowser local governance state as text, JSON, or HTML."""
from __future__ import annotations

import argparse
import html
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Any


def default_events() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "provenance" / "events.jsonl"


def default_actions() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "policy" / "actions.jsonl"


def default_memory() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "memory" / "candidates.jsonl"


def default_out() -> Path:
    return Path.home() / "Library" / "Application Support" / "BearBrowser" / "sidecar" / "status.html"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(item, dict):
                records.append(item)
    return records


def unresolved_memory(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    resolved = {str(record.get("resolvesMemoryId")) for record in records if record.get("resolvesMemoryId")}
    return [record for record in records if record.get("state") == "candidate" and record.get("memoryId") not in resolved]


def summarize(events: list[dict[str, Any]], actions: list[dict[str, Any]], memory: list[dict[str, Any]]) -> dict[str, Any]:
    event_types = Counter(str(event.get("eventType", "unknown")) for event in events)
    surfaces = Counter(str(event.get("surface", "unknown")) for event in events)
    action_types = Counter(str(action.get("actionType", "unknown")) for action in actions)
    decisions = Counter(str(action.get("decision", {}).get("state", "unknown")) for action in actions)
    risk = Counter(str(action.get("risk", {}).get("level", "unknown")) for action in actions)
    memory_states = Counter(str(record.get("state", "unknown")) for record in memory)
    memory_classes = Counter(str(record.get("classification", {}).get("payloadClass", "unknown")) for record in memory)
    pending_memory = unresolved_memory(memory)

    return {
        "product": "BearBrowser",
        "status": "local-sidecar-ready",
        "eventCount": len(events),
        "actionCount": len(actions),
        "memoryCount": len(memory),
        "pendingMemoryCount": len(pending_memory),
        "eventTypes": dict(sorted(event_types.items())),
        "surfaces": dict(sorted(surfaces.items())),
        "actionTypes": dict(sorted(action_types.items())),
        "decisions": dict(sorted(decisions.items())),
        "riskLevels": dict(sorted(risk.items())),
        "memoryStates": dict(sorted(memory_states.items())),
        "memoryClasses": dict(sorted(memory_classes.items())),
        "recentEvents": events[-8:],
        "recentActions": actions[-8:],
        "recentMemory": memory[-8:],
        "pendingMemory": pending_memory[-8:],
    }


def esc(value: Any) -> str:
    return html.escape(str(value), quote=True)


def kv_table(mapping: dict[str, Any]) -> str:
    if not mapping:
        return '<p class="muted">No records.</p>'
    rows = "".join(f"<tr><td>{esc(k)}</td><td>{esc(v)}</td></tr>" for k, v in mapping.items())
    return f"<table><tbody>{rows}</tbody></table>"


def recent_events(events: list[dict[str, Any]]) -> str:
    if not events:
        return '<p class="muted">No provenance events yet.</p>'
    rows = []
    for event in reversed(events[-8:]):
        policy = event.get("policy", {})
        redaction = event.get("redaction", {})
        rows.append(
            "<tr>"
            f"<td>{esc(event.get('timestamp', ''))}</td>"
            f"<td>{esc(event.get('eventType', ''))}</td>"
            f"<td>{esc(event.get('surface', ''))}</td>"
            f"<td>{esc(policy.get('decision', ''))}</td>"
            f"<td>{esc(redaction.get('payloadClass', ''))}</td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Time</th><th>Event</th><th>Surface</th><th>Decision</th><th>Payload</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


def recent_actions(actions: list[dict[str, Any]]) -> str:
    if not actions:
        return '<p class="muted">No policy actions yet.</p>'
    rows = []
    for action in reversed(actions[-8:]):
        risk = action.get("risk", {})
        decision = action.get("decision", {})
        target = action.get("target", {})
        rows.append(
            "<tr>"
            f"<td>{esc(action.get('timestamp', ''))}</td>"
            f"<td>{esc(action.get('actionType', ''))}</td>"
            f"<td>{esc(target.get('kind', ''))}</td>"
            f"<td>{esc(risk.get('level', ''))}</td>"
            f"<td>{esc(decision.get('state', ''))}</td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Time</th><th>Action</th><th>Target</th><th>Risk</th><th>Decision</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


def recent_memory(records: list[dict[str, Any]]) -> str:
    if not records:
        return '<p class="muted">No memory candidates yet.</p>'
    rows = []
    for record in reversed(records[-8:]):
        classification = record.get("classification", {})
        source = record.get("source", {})
        policy = record.get("policy", {})
        text = str(record.get("text", ""))
        if len(text) > 120:
            text = text[:117] + "..."
        rows.append(
            "<tr>"
            f"<td>{esc(record.get('timestamp', ''))}</td>"
            f"<td>{esc(record.get('state', ''))}</td>"
            f"<td>{esc(source.get('kind', ''))}</td>"
            f"<td>{esc(classification.get('payloadClass', ''))}</td>"
            f"<td>{esc(policy.get('decision', ''))}</td>"
            f"<td>{esc(text)}</td>"
            "</tr>"
        )
    return "<table><thead><tr><th>Time</th><th>State</th><th>Source</th><th>Class</th><th>Decision</th><th>Text</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>"


def render_html(summary: dict[str, Any]) -> str:
    events = summary["recentEvents"]
    actions = summary["recentActions"]
    memory = summary["recentMemory"]
    pending_memory = summary["pendingMemory"]
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BearBrowser Sidecar Status</title>
<style>
:root {{ color-scheme: dark; --bg:#17130f; --panel:#252018; --line:#5f432f; --text:#f5eee5; --muted:#cbbbaa; --gold:#f6d28b; --ok:#9be28f; --hold:#f6d28b; --deny:#ff9d9d; }}
* {{ box-sizing:border-box; }} body {{ margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:radial-gradient(circle at 22% 10%,#39281c 0,#17130f 42%,#0f0d0b 100%); color:var(--text); }}
main {{ max-width:1180px; margin:0 auto; padding:42px 24px 80px; }}
h1 {{ font-size:44px; margin:0 0 8px; }} h2 {{ margin:0 0 16px; }} p {{ color:var(--muted); line-height:1.55; }}
.grid {{ display:grid; grid-template-columns:repeat(5,1fr); gap:16px; margin:28px 0; }}
.card {{ border:1px solid var(--line); border-radius:22px; background:rgba(37,32,24,.94); padding:20px; box-shadow:0 18px 50px rgba(0,0,0,.22); }}
.metric {{ font-size:36px; font-weight:800; color:var(--gold); }}
section {{ margin-top:22px; }} table {{ width:100%; border-collapse:collapse; overflow:hidden; border-radius:16px; }} th,td {{ text-align:left; padding:11px 12px; border-bottom:1px solid #3c3026; vertical-align:top; }} th {{ color:var(--gold); font-size:13px; text-transform:uppercase; letter-spacing:.04em; }}
.muted {{ color:var(--muted); }} .pill {{ display:inline-block; padding:6px 10px; border-radius:999px; background:#3a3027; color:var(--gold); font-weight:700; }}
@media(max-width:980px) {{ .grid {{ grid-template-columns:1fr 1fr; }} }} @media(max-width:560px) {{ .grid {{ grid-template-columns:1fr; }} }}
</style>
</head>
<body>
<main>
<span class="pill">local governed sidecar</span>
<h1>BearBrowser Sidecar Status</h1>
<p>Local provenance, policy-action, and memory-candidate state. Sensitive-looking memory candidates are blocked before persistence.</p>
<div class="grid">
  <div class="card"><div class="metric">{esc(summary['eventCount'])}</div><p>provenance events</p></div>
  <div class="card"><div class="metric">{esc(summary['actionCount'])}</div><p>policy actions</p></div>
  <div class="card"><div class="metric">{esc(summary['memoryCount'])}</div><p>memory records</p></div>
  <div class="card"><div class="metric">{esc(summary['pendingMemoryCount'])}</div><p>pending memory</p></div>
  <div class="card"><div class="metric">{esc(summary['decisions'].get('hold', 0))}</div><p>held actions</p></div>
</div>
<section class="card"><h2>Event Types</h2>{kv_table(summary['eventTypes'])}</section>
<section class="card"><h2>Policy Decisions</h2>{kv_table(summary['decisions'])}</section>
<section class="card"><h2>Memory States</h2>{kv_table(summary['memoryStates'])}</section>
<section class="card"><h2>Pending Memory Candidates</h2>{recent_memory(pending_memory)}</section>
<section class="card"><h2>Recent Memory Records</h2>{recent_memory(memory)}</section>
<section class="card"><h2>Recent Provenance</h2>{recent_events(events)}</section>
<section class="card"><h2>Recent Policy Actions</h2>{recent_actions(actions)}</section>
</main>
</body>
</html>"""


def print_text(summary: dict[str, Any]) -> None:
    print("BearBrowser sidecar status")
    print(f"events={summary['eventCount']}")
    print(f"actions={summary['actionCount']}")
    print(f"memory={summary['memoryCount']}")
    print(f"pendingMemory={summary['pendingMemoryCount']}")
    print(f"decisions={summary['decisions']}")
    print(f"riskLevels={summary['riskLevels']}")
    print(f"memoryStates={summary['memoryStates']}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Render BearBrowser local sidecar status")
    parser.add_argument("--events", default=str(default_events()))
    parser.add_argument("--actions", default=str(default_actions()))
    parser.add_argument("--memory", default=str(default_memory()))
    parser.add_argument("--format", choices=["text", "json", "html"], default="text")
    parser.add_argument("--out", default=str(default_out()))
    parser.add_argument("--open", action="store_true")
    args = parser.parse_args()

    events = read_jsonl(Path(args.events).expanduser())
    actions = read_jsonl(Path(args.actions).expanduser())
    memory = read_jsonl(Path(args.memory).expanduser())
    summary = summarize(events, actions, memory)

    if args.format == "json":
        print(json.dumps(summary, indent=2, sort_keys=True))
        return 0
    if args.format == "html":
        out = Path(args.out).expanduser()
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(render_html(summary), encoding="utf-8")
        print(f"BearBrowser sidecar status written: {out}")
        if args.open:
            subprocess.run(["open", str(out)], check=False)
        return 0

    print_text(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
