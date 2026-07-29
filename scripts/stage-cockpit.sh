#!/usr/bin/env bash
# stage-cockpit.sh <GRE_DIR> [ASSEMBLED_RESOURCES]
#
# Piece 1 of docs/cockpit-browser-integration-handoff.md: get the assembled
# sovereign cockpit INTO the packaged app, so the browser ships it rather than a
# manual localhost runner.
#
#   <GRE_DIR>              the app's resource base (same arg shape as
#                          stage-bearnet.sh): <App>.app/Contents/Resources,
#                          <dist>/bearbrowser, or <dist>/firefox
#   [ASSEMBLED_RESOURCES]  output of scripts/assemble-cockpit.sh
#                          (default: build/app-staging/Contents/Resources)
#
# NO-OP IF NOT ASSEMBLED. assemble-cockpit.sh needs pnpm + bun and produces a
# 68 MB agent-machine binary; that is not wired into CI yet. Rather than fail a
# nightly, this stages what exists and says clearly what it skipped — the
# browser is simply built without the cockpit until assembly runs.
set -uo pipefail

GRE="${1:?usage: stage-cockpit.sh <GRE_DIR> [ASSEMBLED_RESOURCES]}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${2:-$REPO/build/app-staging/Contents/Resources}"
[ -d "$GRE" ] || { echo "stage-cockpit: GRE dir not found: $GRE" >&2; exit 1; }

if [ ! -d "$SRC/cockpit" ]; then
  echo "stage-cockpit: no assembled cockpit at $SRC/cockpit — SKIPPING."
  echo "stage-cockpit:   build it with: bash scripts/assemble-cockpit.sh"
  exit 0
fi

# 1. The UI, loose where a resource://bearbrowser-cockpit/ substitution can
#    reach it — same mechanism proven for resource://bearstart/.
mkdir -p "$GRE/cockpit"
cp -R "$SRC/cockpit/." "$GRE/cockpit/"
echo "stage-cockpit: UI → $GRE/cockpit ($(find "$GRE/cockpit" -type f | wc -l | tr -d ' ') files)"

# 2. The agent-machine sidecar the gate proxies to.
if [ -f "$SRC/sidecars/bearbrowser-agent-machine-bin" ]; then
  mkdir -p "$GRE/sidecars"
  cp "$SRC/sidecars/bearbrowser-agent-machine-bin" "$GRE/sidecars/"
  chmod +x "$GRE/sidecars/bearbrowser-agent-machine-bin"
  echo "stage-cockpit: agent-machine sidecar staged"
else
  echo "stage-cockpit: NOTE agent-machine binary absent — cockpit UI ships, backend will not start"
fi

# 3. The governance gate + contract. The cockpit must never reach the sidecar
#    except through these: every agent action is classified before it runs.
mkdir -p "$GRE/scripts" "$GRE/policy"
for f in bearbrowser-agent-machine bearbrowser-agent-machine-gate.py \
         bearbrowser-receipts.py bearbrowser-cockpit-up agent-control-bridge.py; do
  [ -f "$SRC/scripts/$f" ] && cp "$SRC/scripts/$f" "$GRE/scripts/" 2>/dev/null
  [ -f "$REPO/scripts/$f" ] && [ ! -f "$GRE/scripts/$f" ] && cp "$REPO/scripts/$f" "$GRE/scripts/" 2>/dev/null
done
[ -f "$REPO/policy/bearbrowser-contract.yaml" ] && cp "$REPO/policy/bearbrowser-contract.yaml" "$GRE/policy/"
echo "stage-cockpit: gate + contract → $(ls "$GRE/scripts" 2>/dev/null | wc -l | tr -d ' ') scripts, $(ls "$GRE/policy" 2>/dev/null | wc -l | tr -d ' ') policy"
echo "stage-cockpit: done"
