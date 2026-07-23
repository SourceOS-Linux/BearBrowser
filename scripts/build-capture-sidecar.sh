#!/usr/bin/env bash
# build-capture-sidecar.sh — compile the network-visibility sidecar (packet
# capture + connection map + per-domain firewall) into a single release binary,
# staged into the .app alongside the agent-machine sidecar.
#
# Mirrors build-agent-machine-sidecar.sh: build once, self-smoke, stage. The
# smoke test proves the binary boots, refuses non-loopback, and serves /health —
# and that it REFUSES to run without the canonical policy bridge (the one-engine
# invariant), so a mis-staged app can never ship an ungoverned capture surface.
#
# Env:
#   OUT=/path/to/Contents/Resources/sidecars   # default: build/sidecars staging
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${BEARBROWSER_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT="${OUT:-$REPO_ROOT/build/sidecars}"
CRATE="$REPO_ROOT/capture-sidecar"
BIN_NAME="bearbrowser-capture-sidecar-bin"

log() { printf '[build-capture-sidecar] %s\n' "$*"; }

command -v cargo >/dev/null 2>&1 || { log "ERROR: cargo (Rust) is required. Install: https://rustup.rs"; exit 1; }
[ -f "$CRATE/Cargo.toml" ] || { log "ERROR: crate not found at $CRATE"; exit 1; }

log "cargo build --release ($CRATE)"
cargo build --release --manifest-path "$CRATE/Cargo.toml"

BUILT="$CRATE/target/release/capture-sidecar"
[ -x "$BUILT" ] || { log "ERROR: build produced no binary at $BUILT"; exit 1; }

mkdir -p "$OUT"
cp "$BUILT" "$OUT/$BIN_NAME"
log "staged → $OUT/$BIN_NAME"

# ── Self-smoke ───────────────────────────────────────────────────────────────
# 1. Refuses to run without the bridge (one-engine invariant).
log "smoke 1/3: refuses to start ungoverned (no bridge)"
tmp_nogate="$(mktemp -d)"
if "$OUT/$BIN_NAME" --repo-root "$tmp_nogate" --port 0 >/dev/null 2>&1; then
  log "ERROR: sidecar started WITHOUT a policy bridge — governance invariant broken"
  rm -rf "$tmp_nogate"; exit 1
fi
rm -rf "$tmp_nogate"
log "  ok — refused (no bridge under repo-root)"

# 2 + 3. Boots against the real repo, serves /health, refuses non-loopback.
PORT="${SMOKE_PORT:-8096}"
STATE="$(mktemp -d)"
log "smoke 2/3: boot + /health on 127.0.0.1:$PORT"
BEARBROWSER_REPO_ROOT="$REPO_ROOT" CAPTURE_SIDECAR_STATE="$STATE" \
  "$OUT/$BIN_NAME" --repo-root "$REPO_ROOT" --port "$PORT" >/tmp/capture-smoke.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null; rm -rf "$STATE"' EXIT

ok=""
for _ in $(seq 1 30); do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)" = "200" ]; then
    ok=1; break
  fi
  sleep 0.3
done
[ -n "$ok" ] || { log "ERROR: /health never returned 200"; cat /tmp/capture-smoke.log; exit 1; }
log "  ok — /health 200"

log "smoke 3/3: agent capture-start is gate-denied (403)"
code="$(curl -s -o /dev/null -w '%{http_code}' -XPOST "http://127.0.0.1:$PORT/capture/start" \
  -H 'content-type: application/json' -d '{"actor":"agent","userGesture":false}' 2>/dev/null)"
[ "$code" = "403" ] || { log "ERROR: agent capture-start returned $code, expected 403 (gate not enforcing)"; exit 1; }
log "  ok — agent capture blocked (403)"

log "DONE — $OUT/$BIN_NAME built + smoke-verified"
