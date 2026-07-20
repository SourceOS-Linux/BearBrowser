#!/usr/bin/env bash
# assemble-cockpit.sh — build + stage the FULL sovereign cockpit into a Resources
# layout ready to drop into BearBrowser.app/Contents/Resources/.
#
# OBJ-A of the composition (docs/cockpit-composition-plan.md): fuse the pieces that
# landed across Lanes 1–4 + Receipts into one assembled surface —
#
#   Contents/Resources/
#     ├─ cockpit/                       client-vue, built + config-injected (Lane 2)
#     │    └─ cockpit-config.js         sovereign runtime config (resolver reads it)
#     ├─ sidecars/
#     │    └─ bearbrowser-agent-machine-bin   68M single binary (Lane 3)
#     ├─ policy/bearbrowser-contract.yaml     the enforcing contract (Lane 4)
#     └─ scripts/
#          ├─ bearbrowser-agent-machine       sidecar launcher (Lane 3)
#          ├─ bearbrowser-agent-machine-gate.py   governance gate (Lane 4)
#          ├─ agent-control-bridge.py            the one policy engine
#          ├─ bearbrowser-receipts.py            trust-ledger service (Receipts)
#          └─ bearbrowser-cockpit-up             runtime orchestrator (this OBJ)
#
# Reproducible; pass COCKPIT_SRC / AGENT_MACHINE_SRC to build from local checkouts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${STAGE:-$REPO_ROOT/build/app-staging/Contents/Resources}"
log() { printf '[assemble] %s\n' "$*"; }

log "staging root: $STAGE"
rm -rf "$STAGE"; mkdir -p "$STAGE/scripts" "$STAGE/policy" "$STAGE/sidecars"

# 1. Cockpit (Lane 2) — build client-vue → $STAGE/cockpit + inject sovereign config.
log "building cockpit …"
OUT="$STAGE/cockpit" bash "$REPO_ROOT/scripts/build-cockpit.sh"

# 2. agent-machine sidecar (Lane 3) — bun --compile → $STAGE/sidecars/…-bin (self-smoke).
log "building agent-machine sidecar …"
OUT="$STAGE/sidecars" bash "$REPO_ROOT/scripts/build-agent-machine-sidecar.sh"

# 3. Stage the runtime scripts + the enforcing contract (Lane 4 + Receipts + orchestrator).
log "staging runtime scripts + policy contract …"
for s in bearbrowser-agent-machine bearbrowser-agent-machine-gate.py agent-control-bridge.py \
         bearbrowser-receipts.py bearbrowser-cockpit-up; do
  cp "$REPO_ROOT/scripts/$s" "$STAGE/scripts/$s"
done
cp "$REPO_ROOT/policy/bearbrowser-contract.yaml" "$STAGE/policy/bearbrowser-contract.yaml"
chmod +x "$STAGE/scripts/"*

# 4. Manifest — record what was assembled.
cat > "$STAGE/cockpit-app.manifest.json" <<JSON
{
  "assembled": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cockpit": "cockpit/index.html",
  "sidecar": "sidecars/bearbrowser-agent-machine-bin",
  "gate": "scripts/bearbrowser-agent-machine-gate.py",
  "receipts": "scripts/bearbrowser-receipts.py",
  "orchestrator": "scripts/bearbrowser-cockpit-up",
  "contract": "policy/bearbrowser-contract.yaml",
  "topology": "cockpit -> gate:8080 -> sidecar:8091 ; receipts:8092 ; sovereign loopback only"
}
JSON

log "assembled OK → $STAGE"
log "  cockpit files:  $(find "$STAGE/cockpit" -type f | wc -l | tr -d ' ')"
log "  sidecar:        $(du -h "$STAGE/sidecars/bearbrowser-agent-machine-bin" | cut -f1)"
log "run it: $STAGE/scripts/bearbrowser-cockpit-up"
