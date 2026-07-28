#!/usr/bin/env bash
# stage-bearnet.sh <GRE_DIR> [SIDECAR_BIN]
#
# Stage BearNet into a packaged app so it renders + goes LIVE. Cross-platform:
# <GRE_DIR> is the app's "GreD" (resource base) — the dir that contains the
# `browser/` subdir and the binary:
#   macOS   : <App>.app/Contents/Resources
#   Linux   : <dist>/bearbrowser
#   Windows : <dist>/firefox   (top dir inside the win64 zip)
#
# It stages, all where the autoconfig's resource://bearstart/ substitution + its
# Subprocess launcher expect them:
#   <GRE>/browser/bearstart/   the start page + BearNet panel + fonts + world map
#   <GRE>/sidecars/            the capture sidecar binary the app launches
#   <GRE>/scripts/             agent-control-bridge.py (the governance engine)
#   <GRE>/policy/              the enforcing contract
#   <GRE>/geoip/               DB-IP City + ASN (the map + who-owns-it data)
#
# Why loose (not omni.ja): FINAL_TARGET_FILES doesn't survive `mach package` —
# verified on a real DMG that the branded new-tab was shipping BROKEN.
set -euo pipefail

GRE="${1:?usage: stage-bearnet.sh <GRE_DIR> [SIDECAR_BIN]}"
SIDECAR="${2:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -d "$GRE" ] || { echo "stage-bearnet: GRE dir not found: $GRE" >&2; exit 1; }

# 1. The pages, loose where resource://bearstart/ resolves.
bs="$GRE/browser/bearstart"
mkdir -p "$bs"
for f in bearbrowser-start.html bearnet.html world.json dm-sans-latin.woff2 dm-sans-latin-ext.woff2; do
  [ -f "$REPO/settings/start/$f" ] && cp "$REPO/settings/start/$f" "$bs/"
done
echo "stage-bearnet: pages → $bs ($(ls "$bs" | wc -l | tr -d ' ') files)"

# 2. The sidecar + governance + geo, so BearNet is LIVE (not "offline").
if [ -n "$SIDECAR" ] && [ -f "$SIDECAR" ]; then
  mkdir -p "$GRE/sidecars" "$GRE/scripts" "$GRE/policy" "$GRE/geoip"
  # The autoconfig launcher looks for bearbrowser-capture-sidecar-bin[.exe].
  case "$SIDECAR" in
    *.exe) cp "$SIDECAR" "$GRE/sidecars/bearbrowser-capture-sidecar-bin.exe" ;;
    *)     cp "$SIDECAR" "$GRE/sidecars/bearbrowser-capture-sidecar-bin"; chmod +x "$GRE/sidecars/bearbrowser-capture-sidecar-bin" ;;
  esac
  cp "$REPO/scripts/agent-control-bridge.py" "$GRE/scripts/"
  cp "$REPO/scripts/strip-json-comments.py" "$GRE/scripts/" 2>/dev/null || true
  cp "$REPO/policy/bearbrowser-contract.yaml" "$GRE/policy/"
  bash "$REPO/scripts/fetch-geoip.sh" "$REPO/capture-sidecar/geoip" >/dev/null 2>&1 || true
  for db in dbip-city-lite.mmdb dbip-asn-lite.mmdb; do
    [ -f "$REPO/capture-sidecar/geoip/$db" ] && cp "$REPO/capture-sidecar/geoip/$db" "$GRE/geoip/"
  done
  echo "stage-bearnet: sidecar + bridge + policy + $(ls "$GRE/geoip" 2>/dev/null | wc -l | tr -d ' ') geoip DBs → LIVE"
else
  echo "stage-bearnet: no sidecar binary given — BearNet ships but shows 'offline'"
fi
