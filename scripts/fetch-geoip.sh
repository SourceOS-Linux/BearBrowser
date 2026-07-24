#!/usr/bin/env bash
# fetch-geoip.sh — download the local IP-intelligence databases BearNet uses
# for its map + who-owns-it view: DB-IP City Lite + ASN Lite (MaxMind format,
# CC-BY-4.0). Run at package/assemble time. We ship the REAL city database
# (precise city-level dots), not a country-level stand-in.
#
# The city DB (~131MB uncompressed) is too big to commit, so it's fetched here;
# the ASN DB (~10MB) is committed but re-fetched fine if absent. The sidecar
# loads whatever is present from its geoip dir (CAPTURE_SIDECAR_GEOIP), and
# degrades gracefully if a DB is missing.
#
# Usage: fetch-geoip.sh [DEST_DIR]   (default: capture-sidecar/geoip)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${1:-$REPO_ROOT/capture-sidecar/geoip}"
mkdir -p "$DIR"

# DB-IP publishes month-stamped files; the current month may not exist early on,
# so try this month then fall back to last month.
months() {
  date +%Y-%m
  if date -v-1m +%Y-%m >/dev/null 2>&1; then date -v-1m +%Y-%m; else date -d 'last month' +%Y-%m; fi
}

fetch() {   # <out-filename> <db-ip-base-name>
  local out="$DIR/$1" base="$2"
  if [ -s "$out" ]; then
    echo "[geoip] have $1 ($(du -h "$out" | cut -f1))"
    return 0
  fi
  local m
  for m in $(months); do
    local url="https://download.db-ip.com/free/${base}-${m}.mmdb.gz"
    if curl -fsSL "$url" 2>/dev/null | gunzip > "$out.tmp" 2>/dev/null && [ -s "$out.tmp" ]; then
      mv "$out.tmp" "$out"
      echo "[geoip] fetched $1 ($m, $(du -h "$out" | cut -f1))"
      return 0
    fi
    rm -f "$out.tmp"
  done
  echo "[geoip] WARNING: could not fetch $1 — BearNet map/ASN will be partial" >&2
  return 1
}

fetch dbip-city-lite.mmdb dbip-city-lite   # geolocation (lat/lon/city → map dots)
fetch dbip-asn-lite.mmdb  dbip-asn-lite    # ASN + owning org (who owns the block)
echo "[geoip] ready in $DIR"
