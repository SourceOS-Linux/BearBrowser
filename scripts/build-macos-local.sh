#!/usr/bin/env bash
# Builds BearBrowser from source ON THIS MAC (Apple hardware — Mozilla's build
# tooling won't run on non-Apple OS). Peer of scripts/gcp-build-linux.sh:
#
#   scripts/build-macos-local.sh --dry-run                    # validate env + tools
#   scripts/build-macos-local.sh --profile human-secure       # single profile
#   scripts/build-macos-local.sh --profiles "human-secure tor-mode"
#
# What it does:
#   1. Preflight: macOS + arch + Xcode CLT + disk + python + hg + rustup + jq.
#   2. bash scripts/apply-sourceos-overlays.sh --profile $p       (clone + patch)
#   3. Overwrite $workspace/source/assets/mozconfig with our
#      mozconfig/$profile-macos.mozconfig so mach targets Cocoa, not GTK.
#   4. If tor-mode: re-append -DBEARBROWSER_FORCE_WIN_SPOOF (overlay script did
#      this to the old mozconfig; we replaced it, so redo it here).
#   5. cd $workspace && make bootstrap && make build.
#   6. Locate the built BearBrowser.app under obj-*/dist/, verify --version,
#      tar it into build/macos-artifacts/ and log SHA256.
#
# Nothing here shells out to gsutil, GCP, or GitHub — this driver is local-only.
# The GHA workflow (.github/workflows/build-macos.yaml) invokes this same script.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

PROFILES="${BB_PROFILES:-human-secure}"
# human-secure / agent-runtime build on the mirror's `latest` (150) — that is
# where their anti-fingerprint gecko patches (anti-fp-canvas-text-metrics,
# anti-fp-audio) actually apply: they are 150-authored and REJECT on every 140
# tree (proven — RFPTargets.inc + CanvasRenderingContext2D.cpp hunks fail on both
# 140.0.4 and 140.12.0esr). Keeping the protections means building on 150 and
# dropping the cosmetic MIRROR patches that drift there (handled in the overlay).
# tor-mode is the 140-ESR cohort profile (self-pins 140, omits anti-fp). Override
# with --ref / BB_REF.
REF="${BB_REF:-latest}"
# Non-tor ESR source retarget (apply-sourceos-overlays.sh) — EMPTY by default so
# human-secure/agent-runtime stay on the 150 source where anti-fp applies. Set it
# only if you deliberately want an ESR source (and have rebased anti-fp to match).
export BEARBROWSER_FIREFOX_VERSION="${BEARBROWSER_FIREFOX_VERSION-}"
DRY_RUN=""
SKIP_BOOTSTRAP=""
KEEP=""
ART_DIR="${BB_ARTIFACTS:-$repo_root/build/macos-artifacts}"
MIN_FREE_GB="${BB_MIN_FREE_GB:-30}"

usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  cat <<USAGE

Options:
  --profile P            Single profile (human-secure | tor-mode | agent-runtime)
  --profiles "P Q"       Multiple profiles, quoted, space-separated
  --ref REF              Mirror ref to build (default: $REF; tor-mode self-pins 140)
  --skip-bootstrap       Assume mach bootstrap has already run (faster re-runs)
  --dry-run              Preflight only — no clone, no build
  --keep                 Do not delete the workspace on success (for debugging)
  --artifacts DIR        Where to write tarballs + logs (default: $ART_DIR)
  -h, --help             This help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)        PROFILES="${2:?}"; shift 2 ;;
    --profiles)       PROFILES="${2:?}"; shift 2 ;;
    --ref)            REF="${2:?}"; shift 2 ;;
    --skip-bootstrap) SKIP_BOOTSTRAP="1"; shift ;;
    --dry-run)        DRY_RUN="1"; shift ;;
    --keep)           KEEP="1"; shift ;;
    --artifacts)      ART_DIR="${2:?}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$ART_DIR"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# ── PREFLIGHT ──────────────────────────────────────────────────────────────────
os="$(uname -s)"
arch="$(uname -m)"
if [ "$os" != "Darwin" ]; then
  echo "FATAL: this script only runs on macOS (found: $os). For Linux use scripts/gcp-build-linux.sh." >&2
  exit 1
fi
case "$arch" in
  arm64|x86_64) ;;
  *) echo "FATAL: unsupported macOS arch: $arch" >&2; exit 1 ;;
esac
log "host: $(sw_vers -productName) $(sw_vers -productVersion) ($arch)"

# Xcode Command Line Tools — mach bootstrap needs clang/xcrun/make.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "FATAL: Xcode Command Line Tools not installed. Run: xcode-select --install" >&2
  exit 1
fi
log "xcode CLT: $(xcode-select -p)"

# Disk headroom. Firefox source tree + objdir is ~30 GB per profile. Multiply
# for multi-profile runs; a shared source clone would save some but each profile
# gets its own workspace by design (patches diverge).
# Portable free-space check. GNU df (from Homebrew coreutils) does not accept
# -g; BSD df does not accept --output=. Use -k (POSIX) and convert KiB -> GiB.
free_kb="$(/bin/df -Pk "$repo_root" | awk 'NR==2{print $4}')"
free_gb=$(( free_kb / 1024 / 1024 ))
need_gb=$((MIN_FREE_GB * $(echo "$PROFILES" | wc -w | tr -d ' ')))
log "disk: ${free_gb} GB free at $repo_root (need ~${need_gb} GB for [$PROFILES])"
if [ "$free_gb" -lt "$need_gb" ]; then
  echo "FATAL: insufficient disk. Free ${free_gb} GB < required ~${need_gb} GB." >&2
  echo "  Options: --profile <one>  |  set BB_ARTIFACTS to an external volume  |  free space." >&2
  exit 1
fi

# Interpreter deps mach expects — install via Homebrew if missing.
missing=""
for t in python3 hg curl wget git; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  echo "FATAL: missing required tools:$missing" >&2
  echo "  Install with:  brew install mercurial python@3 wget" >&2
  exit 1
fi
log "tools: python3=$(python3 --version 2>&1) hg=$(hg --version 2>&1 | head -1)"

# Validate profiles + mozconfigs exist BEFORE cloning anything.
for p in $PROFILES; do
  case "$p" in
    human-secure|tor-mode|agent-runtime) ;;
    *) echo "FATAL: unknown profile '$p'" >&2; exit 1 ;;
  esac
  mc="$repo_root/mozconfig/${p}-macos.mozconfig"
  if [ ! -f "$mc" ]; then
    echo "FATAL: missing macOS mozconfig: $mc" >&2
    exit 1
  fi
done

if [ -n "$DRY_RUN" ]; then
  log "DRY RUN complete — preflight passed for [$PROFILES]"
  exit 0
fi

# ── BUILD LOOP (one profile at a time; on failure keep going for the rest) ────
overall_fail=0
for profile in $PROFILES; do
  log "═════════════════ PROFILE: $profile ═════════════════"
  pfx="$ART_DIR/$profile"
  mkdir -p "$pfx"

  log "[$profile] applying sourceos overlays (ref=$REF)..."
  if ! bash "$repo_root/scripts/apply-sourceos-overlays.sh" \
         --profile "$profile" --ref "$REF" \
         > "$pfx/overlay.log" 2>&1; then
    log "[$profile] FAIL: overlay — see $pfx/overlay.log"
    tail -25 "$pfx/overlay.log" | sed "s/^/  [$profile] /"
    overall_fail=1
    continue
  fi

  ws="$(find "$repo_root/build/workspaces" -maxdepth 2 -type d -name source \
         -path "*${profile}-*" 2>/dev/null | sort | tail -1)"
  if [ -z "$ws" ] || [ ! -f "$ws/Makefile" ]; then
    log "[$profile] FAIL: no workspace/Makefile produced by overlay"
    overall_fail=1
    continue
  fi
  workspace_root="$(dirname "$ws")"
  log "[$profile] workspace: $workspace_root"

  # Force macOS mozconfig. The overlay script left the mirror's default in place
  # (LibreWolf ships a Linux/GTK one); replace it with our Cocoa variant.
  mc_src="$repo_root/mozconfig/${profile}-macos.mozconfig"
  mc_dst="$ws/assets/mozconfig"
  mkdir -p "$(dirname "$mc_dst")"
  cp "$mc_src" "$mc_dst"
  # Sovereign macOS SDK. Mozilla's build fetches a pinned SDK toolchain via
  # unpack-sdk.py, which — with MOZ_AUTOMATION set — rewrites the URL to their
  # internal proxy (403 for us) and otherwise leans on Apple's rot-prone swcdn.
  # Instead we package the LICENSED Xcode SDK into our own toolchain artifact
  # (scripts/provision-macos-sdk.sh), pin it, optionally vendor it to our
  # sovereign store, and point configure at it — no external CDN dependency.
  if sdk_eval="$(bash "$repo_root/scripts/provision-macos-sdk.sh")"; then
    eval "$sdk_eval"
  fi
  if [ -n "${BEARBROWSER_MACOS_SDK:-}" ] && [ -d "${BEARBROWSER_MACOS_SDK:-/nonexistent}" ]; then
    printf '\nac_add_options --with-macos-sdk=%s\n' "$BEARBROWSER_MACOS_SDK" >> "$mc_dst"
    log "[$profile] sovereign macOS SDK: $BEARBROWSER_MACOS_SDK"
  else
    log "[$profile] WARNING: sovereign SDK provisioning failed — build may hit Mozilla's 403 SDK fetch"
  fi
  log "[$profile] installed macOS mozconfig -> $mc_dst"

  # tor-mode: overlay-script appended -DBEARBROWSER_FORCE_WIN_SPOOF to the OLD
  # mozconfig; we just overwrote it. Re-append.
  if [ "$profile" = "tor-mode" ]; then
    if ! grep -q "BEARBROWSER_FORCE_WIN_SPOOF" "$mc_dst"; then
      {
        echo ''
        echo '# BearBrowser Tor mode: present the Windows identity (Tor Browser cohort).'
        echo 'export CXXFLAGS="${CXXFLAGS} -DBEARBROWSER_FORCE_WIN_SPOOF"'
      } >> "$mc_dst"
      log "[$profile] re-appended -DBEARBROWSER_FORCE_WIN_SPOOF (Tor Windows-identity spoof)"
    fi
  fi

  # Build. The LibreWolf wrapper Makefile drives `mach bootstrap` and `mach
  # build`. Not set -e in the subshell so we capture the rc, not abort.
  bootstrap_step="make bootstrap"
  if [ -n "$SKIP_BOOTSTRAP" ]; then
    log "[$profile] --skip-bootstrap: assuming Mozilla toolchain is already installed"
    bootstrap_step="true"
  fi
  (
    cd "$ws" || exit 1
    # MOZ_AUTOMATION makes unpack-sdk.py rewrite the macOS SDK URL to Mozilla's
    # internal `http://taskcluster/...` proxy (403 off their network). We provide
    # the SDK ourselves (--with-macos-sdk above), so this must not be set. Log its
    # prior state for diagnosis, then clear it for the whole build.
    echo "=== MOZ_AUTOMATION before build: '${MOZ_AUTOMATION:-<unset>}' (clearing it) ==="
    unset MOZ_AUTOMATION
    echo "=== $bootstrap_step (toolchain + fetch/extract/patch Firefox) ==="
    MOZBUILD_STATE_PATH="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}" $bootstrap_step || exit 11
    echo "=== make build (compile — the long step) ==="
    make build || exit 12
  ) > "$pfx/build.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    log "[$profile] FAIL: build rc=$rc — see $pfx/build.log (last 25 lines):"
    tail -25 "$pfx/build.log" | sed "s/^/  [$profile] /"
    overall_fail=1
    continue
  fi

  # Locate the .app. Firefox mac builds land at obj-*/dist/*.app.
  app="$(find "$ws" -type d -maxdepth 6 \
           \( -name 'BearBrowser.app' -o -name 'LibreWolf.app' -o -name 'Firefox.app' -o -name 'Nightly.app' \) \
           -path '*/dist/*' 2>/dev/null | head -1)"
  if [ -z "$app" ]; then
    log "[$profile] FAIL: build succeeded but no .app found under */dist/"
    find "$ws" -type d -maxdepth 6 -name '*.app' 2>/dev/null | head -10 | sed "s/^/  [$profile] found: /"
    overall_fail=1
    continue
  fi
  log "[$profile] BUILT: $app"
  bin_in_app="$app/Contents/MacOS/bearbrowser"
  [ ! -x "$bin_in_app" ] && bin_in_app="$(find "$app/Contents/MacOS" -maxdepth 1 -type f -perm -u+x 2>/dev/null | head -1)"
  if [ -x "$bin_in_app" ]; then
    "$bin_in_app" --version > "$pfx/version.txt" 2>&1 || true
    log "[$profile] version: $(cat "$pfx/version.txt" 2>/dev/null | head -1)"
  fi

  # Package the .app as a tarball for CI-style distribution + local install.
  tarball="$ART_DIR/bearbrowser-${profile}-macos-${arch}.tar.gz"
  ( cd "$(dirname "$app")" && tar -czf "$tarball" "$(basename "$app")" ) || {
    log "[$profile] FAIL: tar packaging"
    overall_fail=1
    continue
  }
  sha="$(shasum -a 256 "$tarball" | awk '{print $1}')"
  size="$(du -h "$tarball" | awk '{print $1}')"
  printf '%s  %s\n' "$sha" "$(basename "$tarball")" > "$tarball.sha256"
  log "[$profile] packaged: $tarball ($size) sha256=$sha"

  if [ -z "$KEEP" ]; then
    log "[$profile] cleaning workspace (use --keep to retain)"
    rm -rf "$workspace_root"
  fi
  log "═════════════════ DONE: $profile ═════════════════"
done

log "artifacts in $ART_DIR:"
ls -lh "$ART_DIR" 2>/dev/null | sed 's/^/  /'

if [ "$overall_fail" -ne 0 ]; then
  log "ONE OR MORE PROFILES FAILED"
  exit 1
fi
log "ALL PROFILES OK"
exit 0
