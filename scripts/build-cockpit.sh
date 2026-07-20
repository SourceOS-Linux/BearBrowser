#!/usr/bin/env bash
# build-cockpit.sh — compile the SocioProphet cockpit (client-vue) into a static
# bundle embedded in the .app at Contents/Resources/cockpit/, offline-first.
#
# Lane 2 of docs/cockpit-composition-plan.md. The embedded cockpit is the SAME
# client-vue that ships to prophet-platform (GKE) and Firebase — one codebase, three
# surfaces. What makes it modular is the runtime resolver (client-vue
# src/config/cockpitRuntime.ts): it reads window.__COCKPIT_CONFIG__ at boot, so the
# embed runs in SOVEREIGN mode against loopback sidecars with no off-device egress.
#
# Source is reproducible: clone SocioProphet/socioprophet at a pinned ref, or point
# COCKPIT_SRC at a local checkout (dev/CI cache).
#
#   COCKPIT_SRC=/path/to/socioprophet   # optional: skip the clone, use a local repo
#   COCKPIT_REF=<git ref>               # default: master
#   OUT=/path/to/Contents/Resources/cockpit   # default: build/cockpit staging
#
# Idempotent; no network needed when COCKPIT_SRC is set.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COCKPIT_REF="${COCKPIT_REF:-master}"
OUT="${OUT:-$REPO_ROOT/build/cockpit}"
WORK="$REPO_ROOT/build/.cockpit-src"
CLIENT_VUE_SUBDIR="socioprophet-web/client-vue"

log() { printf '[build-cockpit] %s\n' "$*"; }

# 1. Resolve the cockpit source ------------------------------------------------
if [ -n "${COCKPIT_SRC:-}" ]; then
  SRC="$COCKPIT_SRC/$CLIENT_VUE_SUBDIR"
  log "using local cockpit source: $SRC"
else
  log "cloning SocioProphet/socioprophet@$COCKPIT_REF (shallow)"
  rm -rf "$WORK"
  git clone --depth 1 --branch "$COCKPIT_REF" \
    "${COCKPIT_GIT_URL:-https://github.com/SocioProphet/socioprophet.git}" "$WORK"
  SRC="$WORK/$CLIENT_VUE_SUBDIR"
fi
[ -d "$SRC" ] || { log "ERROR: client-vue not found at $SRC"; exit 1; }
grep -q "resolveBase" "$SRC/src/config/cockpitRuntime.ts" 2>/dev/null \
  || { log "ERROR: cockpit source lacks the runtime resolver (needs socioprophet #468 landed)"; exit 1; }

# 2. Build the static bundle ---------------------------------------------------
log "npm ci + build in $SRC"
( cd "$SRC" && npm ci --no-audit --no-fund && npm run build )
[ -f "$SRC/dist/index.html" ] || { log "ERROR: build produced no dist/index.html"; exit 1; }

# 3. Stage into the cockpit resource dir --------------------------------------
log "staging → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$SRC/dist/." "$OUT/"

# 4. Inject the runtime config loader BEFORE the app bundle -------------------
# cockpit-config.js sets window.__COCKPIT_CONFIG__ for sovereign (loopback) mode.
# BearBrowser rewrites the sidecar ports into this file at launch (they're ephemeral);
# the committed template is the sovereign default so the cockpit is usable pre-rewrite.
cp "$REPO_ROOT/runtime/cockpit-config.js" "$OUT/cockpit-config.js"
if ! grep -q 'cockpit-config.js' "$OUT/index.html"; then
  # insert as the first <head> child so it runs before the module bundle
  perl -0pi -e 's{(<head[^>]*>)}{$1\n    <script src="./cockpit-config.js"></script>}' "$OUT/index.html"
  log "injected cockpit-config.js loader into index.html"
fi

log "done: embedded cockpit at $OUT ($(find "$OUT" -type f | wc -l | tr -d ' ') files)"
