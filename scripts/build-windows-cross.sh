#!/usr/bin/env bash
# build-windows-cross.sh — cross-compile BearBrowser for Windows x86_64 FROM LINUX.
#
# Proven end-to-end 2026-07-22 on sovereign-linux-builder (c2d-standard-32):
# produces firefox-<ver>.en-US.win64.zip (portable) and .win64.installer.exe (NSIS)
# in <srcdir>/obj-win64/dist/.
#
# Usage:
#   scripts/build-windows-cross.sh --srcdir <patched bearbrowser source dir> [--setup-only]
#
# The srcdir is the workspace produced by apply-sourceos-overlays.sh + make fetch +
# make dir (same as the Linux lane), e.g.
#   build/workspaces/human-secure-150.0.1-1/source/bearbrowser-150.0.1-1
#
# Assumes `mach bootstrap` has run once on this host for the Linux build (that is
# what provides ~/.mozbuild/clang [clang-cl + llvm-rc/lib/mt] and cbindgen 0.29.1).
#
# HARD-WON GOTCHAS ENCODED HERE — do not "simplify" them away:
#  * vsdownload leaves every .exe non-executable  -> chmod, or VC detection silently fails
#  * MS SDK headers include each other with arbitrary case (objidl.Idl -> objidlbase.idl,
#    kernelspecs.h -> DriverSpecs.h vs driverspecs.h on disk). Symlink games do NOT
#    converge; the fix is a ciopfs case-insensitive mount over a lowercased backing tree.
#  * ciopfs holds one fd per open backing file: the DAEMON needs ulimit -n raised, not
#    just the build (32-way clang-cl through FUSE blows the default 1024 instantly).
#  * configure wants `7zz` (modern 7-Zip standalone), NOT `7z`/`7za` from p7zip-full;
#    missing it fails LATE with `KeyError: '7Z'` after the zip already packaged.
#  * crates.io API 403s without a User-Agent; use static.crates.io.

set -euo pipefail

SRCDIR=""
SETUP_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --srcdir) SRCDIR="$2"; shift 2 ;;
    --setup-only) SETUP_ONLY=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SRCDIR" ] || { echo "--srcdir required" >&2; exit 2; }
SRCDIR="$(cd "$SRCDIR" && pwd)"

VS_DIR="${VS_DIR:-$HOME/vs}"           # raw (lowercased) VS+SDK backing store
VSX_DIR="${VSX_DIR:-$HOME/vsx}"        # ciopfs case-insensitive view -> WINSYSROOT
APPSDK_DIR="${APPSDK_DIR:-$HOME/winappsdk/dir}"
WINRS_DIR_ROOT="${WINRS_DIR_ROOT:-$HOME/winrs}"
# Honor MOZBUILD_STATE_PATH: CI bootstraps into $GITHUB_WORKSPACE/.mozbuild, not
# ~/.mozbuild — clang/cbindgen live wherever mach bootstrap put them.
MSP="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}"
MOZ_CLANG_BIN="${MOZ_CLANG_BIN:-$MSP/clang/bin}"
# Raise fds as high as this host allows (GitHub runners cap the hard limit at
# 65536 — plenty at CI parallelism; the sovereign builder allows 1048576).
NOFILE=$(ulimit -Hn)

log() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- host packages
log "host packages"
sudo apt-get update -qq
sudo apt-get install -y -qq \
  msitools nasm wine64 wine nsis upx-ucl ciopfs fuse python3 unzip curl
# `7zz` — modern 7-Zip standalone binary name that moz.configure's check_prog wants.
sudo apt-get install -y -qq 7zip || true
command -v 7zz >/dev/null || sudo ln -sf "$(command -v 7z)" /usr/local/bin/7zz

# ------------------------------------------------------- MSVC + Windows SDK
if [ ! -d "$VS_DIR/vc" ] && [ ! -d "$VS_DIR/VC" ]; then
  log "downloading MSVC + Windows SDK via msvc-wine vsdownload.py (~4G)"
  tmp=$(mktemp -d)
  git clone --depth 1 https://github.com/mstorsjo/msvc-wine "$tmp/msvc-wine"
  python3 "$tmp/msvc-wine/vsdownload.py" --accept-license --dest "$VS_DIR"
  rm -rf "$tmp"
fi

log "chmod +x every .exe (vsdownload leaves them non-executable)"
find "$VS_DIR" -iname '*.exe' -exec chmod +x {} + 2>/dev/null || true

log "lowercase-rename VS backing tree (ciopfs requires lowercase backing)"
find "$VS_DIR" -depth | while IFS= read -r p; do
  d=${p%/*}; b=${p##*/}
  lb=$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')
  [ "$b" != "$lb" ] && [ ! -e "$d/$lb" ] && mv "$p" "$d/$lb" || true
done

log "mount ciopfs case-insensitive view (daemon gets raised fd limit)"
mkdir -p "$VSX_DIR"
mountpoint -q "$VSX_DIR" || \
  setsid bash -c "ulimit -n $NOFILE; exec ciopfs -f '$VS_DIR' '$VSX_DIR'" \
    >/dev/null 2>&1 < /dev/null &
for i in $(seq 1 20); do mountpoint -q "$VSX_DIR" && break; sleep 1; done
mountpoint -q "$VSX_DIR" || { echo "ciopfs mount failed" >&2; exit 1; }
CPID=$(pgrep -x ciopfs | head -1)
echo "ciopfs daemon fd limit: $(awk '/open files/ {print $4}' "/proc/$CPID/limits" 2>/dev/null || echo unknown) (want $NOFILE)"
# sanity: any-case resolution
ls "$VSX_DIR"/*/10/include/*/shared/DriverSpecs.h >/dev/null 2>&1 || \
ls "$VSX_DIR"/*/10/Include/*/shared/DriverSpecs.h >/dev/null 2>&1 || \
  { echo "case-insensitive resolution check failed" >&2; exit 1; }

# ------------------------------------------------------------------- rust + tools
log "rust windows target"
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add x86_64-pc-windows-msvc

CBINDGEN="${CBINDGEN:-$MSP/cbindgen/cbindgen}"
[ -x "$CBINDGEN" ] || { echo "cbindgen not found at $CBINDGEN — run mach bootstrap first" >&2; exit 1; }

# --------------------------------------------------------------- WinAppSDK DLLs
if [ ! -f "$APPSDK_DIR/CoreMessagingXP.dll" ]; then
  log "fetching WindowsAppSDK redist (DLLs are spread across all four x64 msix)"
  base=$(dirname "$APPSDK_DIR"); mkdir -p "$base" "$APPSDK_DIR"; cd "$base"
  curl -fsSL -o redist.zip \
    "https://aka.ms/windowsappsdk/1.8/1.8.251106002/Microsoft.WindowsAppRuntime.Redist.1.8.zip"
  echo "57748c37e2b0ce381518bbe7ac72e015c150771a343af89f9f0bd95aa5e9bbc0  redist.zip" | sha256sum -c -
  rm -rf ex && mkdir ex && (cd ex && unzip -oq ../redist.zip)
  for msix in ex/MSIX/win10-x64/*.msix; do
    t=$(mktemp -d); (cd "$t" && unzip -oq "$base/$msix" || true)
    for d in CoreMessagingXP.dll marshal.dll Microsoft.InputStateManager.dll \
             Microsoft.Internal.FrameworkUdk.dll Microsoft.UI.Composition.OSSupport.dll \
             Microsoft.UI.Input.dll Microsoft.UI.Windowing.Core.dll Microsoft.UI.Windowing.dll; do
      s=$(find "$t" -name "$d" | head -1); [ -n "$s" ] && cp -n "$s" "$APPSDK_DIR/" || true
    done
    rm -rf "$t"
  done
  [ "$(ls "$APPSDK_DIR" | wc -l)" -eq 8 ] || { echo "expected 8 WinAppSDK DLLs" >&2; exit 1; }
fi

# ------------------------------------------------------------ windows rust crate
WINRS_VER=$(grep -m1 '^version' "$SRCDIR/build/rust/windows/Cargo.toml" | sed -E 's/.*"([^"]+)".*/\1/')
WINRS_DIR="$WINRS_DIR_ROOT/windows-$WINRS_VER"
if [ ! -f "$WINRS_DIR/Cargo.toml" ]; then
  log "fetching windows crate $WINRS_VER (static.crates.io — API 403s w/o UA)"
  mkdir -p "$WINRS_DIR_ROOT"; cd "$WINRS_DIR_ROOT"
  curl -fsSL -A "bearbrowser-build/1.0" -o windows.crate \
    "https://static.crates.io/crates/windows/windows-$WINRS_VER.crate"
  tar xf windows.crate
fi

[ "$SETUP_ONLY" = "1" ] && { log "setup complete (--setup-only)"; exit 0; }

# ------------------------------------------------------------------------ build
log "configure + build + package"
cd "$SRCDIR"
export MOZBUILD_STATE_PATH="$MSP"
export WINSYSROOT="$VSX_DIR"
export MOZ_WINDOWS_APP_SDK_DIR="$APPSDK_DIR"
export MOZ_WINDOWS_RS_DIR="$WINRS_DIR"
export CBINDGEN MOZ_CLANG_BIN
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "$REPO_ROOT/mozconfig/human-secure-win64.mozconfig" "$SRCDIR/mozconfig.win64"
export MOZCONFIG="$SRCDIR/mozconfig.win64"
export PATH="$MOZ_CLANG_BIN:$HOME/.cargo/bin:$PATH"
ulimit -n "$NOFILE"

./mach configure
./mach build
./mach package

log "artifacts"
ls -la "$SRCDIR"/obj-win64/dist/*.win64.zip "$SRCDIR"/obj-win64/dist/*.win64.installer.exe
