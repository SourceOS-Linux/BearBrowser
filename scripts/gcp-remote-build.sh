#!/usr/bin/env bash
# Runs ON the GCP build VM (Ubuntu). Builds one or more BearBrowser profiles from
# source (full Gecko compile with our engine patches), measures the real binary,
# and stages artifacts in ~/artifacts. Driven by scripts/gcp-build-linux.sh.
#
# Not set -e: one profile failing must not abort the others. Each profile is
# isolated and its failures are logged + collected.
set -uo pipefail

profiles="${1:-human-secure tor-mode}"
repo="${BB_REPO:-$HOME/BearBrowser}"
art="$HOME/artifacts"
mkdir -p "$art"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }
fail=0

log "BearBrowser GCP build — profiles: [$profiles]"
log "cores=$(nproc) mem=$(free -g | awk '/Mem:/{print $2}')GB disk_free=$(df -h "$HOME" | awk 'NR==2{print $4}')"

# ── Base OS dependencies (Mozilla's own toolchain comes from `mach bootstrap`) ──
log "Installing base apt dependencies..."
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  git python3 python3-dev python3-pip python3-venv curl wget mercurial zstd \
  build-essential pkg-config libssl-dev libxml2-dev nodejs npm xz-utils \
  >/dev/null 2>&1 || log "WARN: some apt deps failed (continuing — mach bootstrap covers most)"

# Node deps for the fingerprint scorecard (geckodriver + selenium are in package.json).
cd "$repo" || { log "FATAL: repo not found at $repo"; exit 1; }
log "Installing node measurement deps..."
npm ci >/dev/null 2>&1 || npm install >/dev/null 2>&1 || log "WARN: npm deps failed (scorecard may be skipped)"

for p in $profiles; do
  log "=================== PROFILE: $p ==================="
  pfail=0

  log "[$p] overlay prep (apply-sourceos-overlays --profile $p)..."
  if ! bash scripts/apply-sourceos-overlays.sh --profile "$p" --ref latest > "$art/$p-overlay.log" 2>&1; then
    log "[$p] FAIL: overlay prep — see $p-overlay.log"; fail=1; continue
  fi
  ws="$(find build/workspaces -maxdepth 2 -type d -name source 2>/dev/null | sort | tail -1)"
  if [ -z "$ws" ] || [ ! -f "$ws/Makefile" ]; then
    log "[$p] FAIL: no workspace/Makefile produced"; fail=1; continue
  fi
  log "[$p] workspace: $ws (firefox version: $(cat "$ws/version" 2>/dev/null))"

  (
    cd "$ws" || exit 1
    echo "=== make bootstrap (Mozilla toolchain + fetch/extract/patch source) ==="
    MOZBUILD_STATE_PATH="$HOME/.mozbuild" make bootstrap || exit 11
    echo "=== make build (compile — the long step) ==="
    make build || exit 12
  ) > "$art/$p-build.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "[$p] FAIL: build rc=$rc — see $p-build.log (tail below)"; tail -25 "$art/$p-build.log"; fail=1; continue
  fi

  # The branded build names the binary bearbrowser/librewolf, not firefox.
  bin="$(find "$ws" -type f \( -name bearbrowser -o -name librewolf -o -name firefox \) -path '*dist/bin*' 2>/dev/null | head -1)"
  if [ -z "$bin" ]; then
    log "[$p] FAIL: build succeeded but no dist/bin binary found (looked for bearbrowser/librewolf/firefox)"
    find "$ws" -type f -path '*dist/bin*' 2>/dev/null | grep -viE '\.(so|js|json|txt|xpi|ini)$' | head -20
    fail=1; continue
  fi
  log "[$p] BUILT: $bin"
  "$bin" --version > "$art/$p-version.txt" 2>&1 || true

  # Firefox RUNTIME libs — `mach bootstrap` installs BUILD deps, not run deps, so
  # geckodriver couldn't launch the binary headless (empty scorecard). Install once.
  if [ ! -f /tmp/.bb-runtime-deps ]; then
    log "installing Firefox runtime libs for the scorecard..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      libgtk-3-0t64 libdbus-glib-1-2 libxt6t64 libasound2t64 libx11-xcb1 libpci3 >/dev/null 2>&1 \
    || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      libgtk-3-0 libdbus-glib-1-2 libxt6 libasound2 libx11-xcb1 libpci3 >/dev/null 2>&1 || true
    touch /tmp/.bb-runtime-deps
  fi

  # ── Scorecard: drive the REAL binary (authoritative) ──
  log "[$p] measuring fingerprint scorecard..."
  PATH="$repo/node_modules/.bin:$PATH" \
    node scripts/measure-fingerprint.mjs --profile "$p" --bin "$bin" --json \
    > "$art/$p-scorecard.json" 2> "$art/$p-measure.log" || log "[$p] WARN: measurement failed — see $p-measure.log"

  # tor-mode: assert the OS-spoof actually compiled in (Windows identity on this Linux host)
  if [ "$p" = "tor-mode" ] && [ -s "$art/$p-scorecard.json" ]; then
    if grep -q "Windows NT 10.0" "$art/$p-scorecard.json" && grep -q "Win32" "$art/$p-scorecard.json"; then
      log "[$p] ✓ OS-spoof VERIFIED: binary reports Windows identity"
    else
      log "[$p] ✗ OS-spoof NOT present: binary did not report Windows — the mozconfig flag did not take effect"; fail=1
    fi
  fi

  # ── Package the runnable dist for download ──
  distbin="$(dirname "$bin")"          # .../obj-*/dist/bin
  log "[$p] packaging dist..."
  tar -C "$(dirname "$distbin")" -czf "$art/bearbrowser-$p-linux-x86_64.tar.gz" bin 2>/dev/null \
    || log "[$p] WARN: packaging failed"
  log "=================== DONE: $p (size: $(du -h "$art/bearbrowser-$p-linux-x86_64.tar.gz" 2>/dev/null | cut -f1)) ==================="
done

log "Artifacts staged in $art:"
ls -lh "$art" 2>/dev/null | sed 's/^/  /'
[ "$fail" -eq 0 ] && log "ALL PROFILES OK" || log "ONE OR MORE PROFILES FAILED (rc collected; see per-profile logs)"
exit "$fail"
