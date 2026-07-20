#!/usr/bin/env bash
# build-agent-machine-sidecar.sh — compile @noetica/agent-machine into a single
# self-contained loopback-sidecar binary (bun --compile), staged into the .app.
#
# Lane 3 of docs/cockpit-composition-plan.md. The agent-machine is the local
# sovereign brain (server.ts, 823 /api/* routes: graph, pipelines, devspace,
# knowledge, chat). It's pure JS/TS (verified: @socioprophet/hellgraph is pure TS,
# no native addons), so `bun build --compile` collapses it to one executable — no
# node_modules, no host Node required. The heavy LLM runtime (Ollama) is NOT bundled;
# agent-machine downloads it on demand (scripts/provision-runtime.ts) or uses a cloud
# key, and boots + serves the non-chat surfaces without it.
#
# Source is reproducible: clone the noetica repo at a pinned ref, or point
# AGENT_MACHINE_SRC at a local checkout (dev/CI cache). NOTE: this only COMPILES the
# Noetica engine — it never edits it (Noetica lane: package-only).
#
#   AGENT_MACHINE_SRC=/path/to/noetica   # optional: skip the clone, use a local repo
#   AM_REF=<git ref>                     # default: main
#   OUT=/path/to/Contents/Resources/sidecars   # default: build/sidecars staging
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AM_REF="${AM_REF:-main}"
OUT="${OUT:-$REPO_ROOT/build/sidecars}"
WORK="$REPO_ROOT/build/.agent-machine-src"
BIN_NAME="bearbrowser-agent-machine-bin"
AM_SUBDIR="agent-machine"

log() { printf '[build-agent-machine] %s\n' "$*"; }

command -v bun >/dev/null 2>&1 || { log "ERROR: bun is required (bun build --compile). Install: https://bun.sh"; exit 1; }

# 1. Resolve the agent-machine source -----------------------------------------
if [ -n "${AGENT_MACHINE_SRC:-}" ]; then
  SRC="$AGENT_MACHINE_SRC/$AM_SUBDIR"
  log "using local agent-machine source: $SRC"
else
  log "cloning noetica@$AM_REF (shallow)"
  rm -rf "$WORK"
  git clone --depth 1 --branch "$AM_REF" \
    "${NOETICA_GIT_URL:-https://github.com/SocioProphet/noetica.git}" "$WORK"
  SRC="$WORK/$AM_SUBDIR"
fi
[ -f "$SRC/server.ts" ] || { log "ERROR: agent-machine server.ts not found at $SRC"; exit 1; }

# 2. Install deps (only if missing — don't mutate an existing checkout's lockfile) + compile
if [ ! -d "$SRC/node_modules" ]; then
  log "bun install in $SRC (fresh checkout)"
  ( cd "$SRC" && bun install )
else
  log "node_modules present — skipping install (avoids touching the Noetica lockfile)"
fi
mkdir -p "$OUT"
log "bun build --compile server.ts → $OUT/$BIN_NAME"
( cd "$SRC" && bun build ./server.ts --compile --outfile "$OUT/$BIN_NAME" )
[ -x "$OUT/$BIN_NAME" ] || { log "ERROR: compile produced no executable"; exit 1; }

# 3. Smoke: boot on a throwaway loopback port, assert it serves ---------------
PORT=8917
NOETICA_AM_PORT="$PORT" NOETICA_OFFLINE=1 "$OUT/$BIN_NAME" >/tmp/am-sidecar-smoke.log 2>&1 &
PID=$!
for _ in $(seq 1 15); do
  code="$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/status" 2>/dev/null || echo 000)"
  [ "$code" = "200" ] && break
  sleep 1
done
kill "$PID" 2>/dev/null || true
[ "${code:-000}" = "200" ] || { log "ERROR: sidecar binary did not serve /api/status (got $code)"; cat /tmp/am-sidecar-smoke.log; exit 1; }
log "smoke OK: /api/status 200 on 127.0.0.1:$PORT"
log "done: $OUT/$BIN_NAME ($(du -h "$OUT/$BIN_NAME" | cut -f1))"
