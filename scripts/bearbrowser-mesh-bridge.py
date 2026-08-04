#!/usr/bin/env python3
"""BearBrowser ↔ Memory Mesh bridge.

Direction 1 (BearBrowser → mesh):
  Tails ~/Library/Application Support/BearBrowser/provenance/events.jsonl
  and page-summaries.jsonl, then appends high-signal events to the shared
  memory-mesh context.jsonl so TurtleTerm / Noetica / Goose Notes see
  what's being browsed in real time.

Direction 2 (mesh → BearBrowser):
  Reads recent mesh capture/note events and writes them as BearBrowser
  memory candidates so the browser's agent panel has coding context.

Usage:
  bearbrowser-mesh-bridge              # sync once (both directions)
  bearbrowser-mesh-bridge --watch      # watch mode: poll every 20s
  bearbrowser-mesh-bridge --push       # BB → mesh only
  bearbrowser-mesh-bridge --pull       # mesh → BB only
  bearbrowser-mesh-bridge --status     # show sync state
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any
from urllib import request as urlreq

# ── paths ─────────────────────────────────────────────────────────────────────

BB_SUPPORT   = Path.home() / "Library" / "Application Support" / "BearBrowser"
BB_EVENTS    = BB_SUPPORT / "provenance" / "events.jsonl"
BB_SUMMARIES = BB_SUPPORT / "summaries" / "page-summaries.jsonl"
BB_CANDIDATES= BB_SUPPORT / "memory" / "candidates.jsonl"

MESH_DIR     = Path(os.getenv("XDG_STATE_HOME", str(Path.home() / ".local/state"))) \
               / "sourceos" / "memory-mesh"
MESH_JSONL   = MESH_DIR / "context.jsonl"
SYNC_DB      = MESH_DIR / ".bearbrowser-sync.json"

GOOSE_API    = os.getenv("GOOSE_NOTES_API", "http://localhost:8765")
NOETICA_URL  = os.getenv("NOETICA_URL", "http://localhost:7700")

# Events that carry useful browsing signal for the mesh
INTERESTING_EVENTS = {
    "navigation.committed",
    "page.shared_with_agent",
    "memory.committed",
    "memory.candidate_created",
    "browser.capture.create",
    "capture.capture-export",
}

# ── helpers ───────────────────────────────────────────────────────────────────

def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def slugify(s: str) -> str:
    s = re.sub(r"[^\w\s-]", "", s.lower().strip())
    return re.sub(r"[\s_-]+", "-", s)[:60]


def load_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    items: list[dict] = []
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            items.append(json.loads(line))
        except Exception:
            pass
    return items


def append_jsonl(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as fh:
        fh.write(json.dumps(record) + "\n")
    # Keep mesh bounded at 5000 lines
    if path == MESH_JSONL:
        try:
            lines = path.read_text(errors="replace").splitlines()
            if len(lines) > 5000:
                path.write_text("\n".join(lines[-5000:]) + "\n")
        except Exception:
            pass


def load_sync_db() -> dict:
    if SYNC_DB.exists():
        try:
            return json.loads(SYNC_DB.read_text())
        except Exception:
            pass
    return {"bb_to_mesh": [], "mesh_to_bb": []}


def save_sync_db(db: dict) -> None:
    MESH_DIR.mkdir(parents=True, exist_ok=True)
    SYNC_DB.write_text(json.dumps(db, indent=2))


def _noetica_summarize(text: str) -> str:
    """Ask Noetica for a short title; fallback = first 80 chars."""
    try:
        payload = json.dumps({
            "messages": [{"role": "user", "content":
                f"Summarize in ≤8 words (no quotes): {text[:400]}"}],
            "max_tokens": 40,
        }).encode()
        req = urlreq.Request(f"{NOETICA_URL}/api/chat", data=payload,
                             headers={"Content-Type": "application/json"})
        with urlreq.urlopen(req, timeout=3) as r:
            resp = json.load(r)
            content = resp.get("choices", [{}])[0].get("message", {}).get("content", "")
            if content:
                return content.strip()[:80]
    except Exception:
        pass
    return text[:80].replace("\n", " ")


# ── BB → mesh ─────────────────────────────────────────────────────────────────

def _extract_url(event: dict) -> str:
    payload = event.get("payload", {})
    if isinstance(payload, dict):
        for key in ("url", "href", "navigationUrl", "pageUrl"):
            v = payload.get(key, "")
            if v and not v.startswith("moz-"):
                return v
    return ""


def _extract_title(event: dict) -> str:
    payload = event.get("payload", {})
    if isinstance(payload, dict):
        for key in ("title", "pageTitle", "label", "summary"):
            v = payload.get(key, "")
            if v:
                return str(v)[:120]
    url = _extract_url(event)
    return url[:80] if url else event.get("eventType", "browse-event")


def bb_to_mesh(db: dict) -> int:
    """Push new BearBrowser events to the memory mesh."""
    synced = set(db.get("bb_to_mesh", []))
    pushed = 0

    for source_path, kind_tag in [(BB_EVENTS, "browse"), (BB_SUMMARIES, "browse-summary")]:
        events = load_jsonl(source_path)
        for ev in events:
            ev_id = ev.get("eventId", "") or ev.get("summaryId", "")
            if not ev_id or ev_id in synced:
                continue

            ev_type = ev.get("eventType", "")
            if source_path == BB_EVENTS and ev_type not in INTERESTING_EVENTS:
                continue

            # Skip denied policy decisions (don't pollute mesh with blocked attempts)
            policy = ev.get("policy", {})
            if isinstance(policy, dict) and policy.get("decision") == "denied":
                continue

            url   = _extract_url(ev)
            title = _extract_title(ev)
            # If title is just the raw URL (no real page title), ask Noetica for a summary
            if url and title == url[:80]:
                title = _noetica_summarize(url)
            ts    = ev.get("timestamp", now_iso())

            content_parts = []
            if url:
                content_parts.append(f"URL: {url}")
            payload = ev.get("payload", {})
            if isinstance(payload, dict):
                summary = payload.get("summary", payload.get("text", ""))
                if summary:
                    content_parts.append(str(summary)[:300])
            content = "\n".join(content_parts) or ev_type

            append_jsonl(MESH_JSONL, {
                "ts":      ts,
                "kind":    kind_tag,
                "source":  "bearbrowser",
                "title":   title,
                "content": content,
                "url":     url,
                "bb_event_type": ev_type,
                "profile": ev.get("profile", ""),
            })

            synced.add(ev_id)
            pushed += 1

    db["bb_to_mesh"] = list(synced)
    return pushed


# ── mesh → BB ─────────────────────────────────────────────────────────────────

def mesh_to_bb(db: dict) -> int:
    """Pull recent mesh capture/note events into BearBrowser as memory candidates."""
    synced = set(db.get("mesh_to_bb", []))
    mesh_events = load_jsonl(MESH_JSONL)
    pulled = 0

    for ev in mesh_events[-200:]:  # only look at recent 200
        key = ev.get("ts", "") + ev.get("title", "")
        if not key or key in synced:
            continue

        if ev.get("source") == "bearbrowser":
            continue  # don't round-trip our own events

        if ev.get("kind") not in ("capture", "note", "shell-cmd", "ai-response"):
            continue

        title   = ev.get("title", "Context")
        content = ev.get("content", "")
        source  = ev.get("source", "terminal")

        candidate = {
            "schemaVersion": "bearbrowser.memory.candidate.v1",
            "candidateId":   f"mesh-{slugify(key)}-{abs(hash(key)) % 0xFFFF:04x}",
            "timestamp":     ev.get("ts", now_iso()),
            "source": {
                "kind":    "note" if ev.get("kind") == "note" else "automation",
                "product": "TurtleTerm/SourceOS",
                "label":   source,
            },
            "actor": {"type": "system", "id": "memory-mesh"},
            "content": {
                "title":   title,
                "text":    content[:800],
                "tags":    ["mesh", source, ev.get("kind", "capture")],
            },
            "status": "proposed",
            "committed": False,
        }

        append_jsonl(BB_CANDIDATES, candidate)
        synced.add(key)
        pulled += 1

    db["mesh_to_bb"] = list(synced)
    return pulled


# ── active context → BearBrowser sidebar ──────────────────────────────────────

def push_active_context() -> None:
    """Write current mesh active context to a file BB can read for its sidebar."""
    active_path = MESH_DIR / "active.json"
    if not active_path.exists():
        return

    try:
        active = json.loads(active_path.read_text())
    except Exception:
        return

    bb_ctx_path = BB_SUPPORT / "context" / "mesh-active.json"
    bb_ctx_path.parent.mkdir(parents=True, exist_ok=True)
    bb_ctx_path.write_text(json.dumps({
        "schemaVersion": "bearbrowser.context.v1",
        "source": "memory-mesh",
        "updated": now_iso(),
        "cwd": active.get("cwd", ""),
        "branch": active.get("branch", ""),
        "title": active.get("title", ""),
        "hostname": active.get("hostname", ""),
    }, indent=2))


# ── status ────────────────────────────────────────────────────────────────────

def print_status() -> None:
    db = load_sync_db()
    bb_events  = len(load_jsonl(BB_EVENTS))
    bb_summaries = len(load_jsonl(BB_SUMMARIES))
    bb_candidates = len(load_jsonl(BB_CANDIDATES))
    mesh_events = len(load_jsonl(MESH_JSONL))

    print(f"BB provenance events:  {bb_events}")
    print(f"BB page summaries:     {bb_summaries}")
    print(f"BB memory candidates:  {bb_candidates}")
    print(f"Mesh events:           {mesh_events}")
    print(f"BB→mesh synced:        {len(db.get('bb_to_mesh', []))}")
    print(f"Mesh→BB synced:        {len(db.get('mesh_to_bb', []))}")

    # Noetica reachability
    try:
        with urlreq.urlopen(f"{NOETICA_URL}/health", timeout=1):
            print(f"Noetica:               reachable ({NOETICA_URL})")
    except Exception:
        print(f"Noetica:               unreachable ({NOETICA_URL})")


# ── main ──────────────────────────────────────────────────────────────────────

def sync_once(push_only: bool = False, pull_only: bool = False) -> tuple[int, int]:
    MESH_DIR.mkdir(parents=True, exist_ok=True)
    db = load_sync_db()
    pushed = bb_to_mesh(db) if not pull_only else 0
    pulled = mesh_to_bb(db)  if not push_only else 0
    push_active_context()
    save_sync_db(db)
    return pushed, pulled


def main() -> None:
    args = sys.argv[1:]

    if "--status" in args:
        print_status()
        return

    push_only = "--push" in args
    pull_only = "--pull" in args
    watch     = "--watch" in args

    if watch:
        print("bearbrowser-mesh-bridge: watching (poll every 20s, Ctrl+C to stop)", flush=True)
        while True:
            try:
                pushed, pulled = sync_once(push_only, pull_only)
                if pushed or pulled:
                    ts = now_iso()[:19]
                    print(f"  [{ts}] BB→mesh={pushed}  mesh→BB={pulled}", flush=True)
            except Exception as exc:
                print(f"  sync error: {exc}", file=sys.stderr, flush=True)
            time.sleep(20)
    else:
        pushed, pulled = sync_once(push_only, pull_only)
        print(f"BB→mesh {pushed}  ·  mesh→BB {pulled}")


if __name__ == "__main__":
    main()
