#!/usr/bin/env bash
# Vendor the licensed macOS SDK into OUR sovereign registry (zot) as an OCI
# artifact, so the bsys6-macos cross-compile image pulls it from us — never from
# Apple's swcdn or Mozilla's CI proxy. Run ONCE on a licensed Mac (this is a ~30s
# SDK extract + push, NOT a build).
#
#   ZOT_REGISTRY=registry.<sovereign> scripts/vendor-macos-sdk-to-zot.sh
#
# Requires: macOS with Xcode Command Line Tools (for the SDK), and `oras`
# (https://oras.land) with credentials for the zot registry.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

ZOT="${ZOT_REGISTRY:?set ZOT_REGISTRY to the sovereign zot host, e.g. registry.sourceos.internal}"
repo_path="${ZOT_SDK_REPO:-bearbrowser/toolchains/macos-sdk}"

log() { printf '[vendor-macos-sdk-to-zot] %s\n' "$*" >&2; }

if [ "$(uname -s)" != "Darwin" ]; then
  log "FATAL: run on a licensed Mac (needs the Xcode SDK to package)"; exit 1
fi
command -v oras >/dev/null 2>&1 || { log "FATAL: oras not installed (https://oras.land)"; exit 1; }

# 1. Package the licensed SDK using the existing provisioner (prints an export line
#    with the extracted path; we want the tarball it wrote alongside).
log "packaging licensed SDK via provision-macos-sdk.sh ..."
eval "$(bash "$repo_root/scripts/provision-macos-sdk.sh")"   # sets BEARBROWSER_MACOS_SDK
sdk_ver="$(xcrun --show-sdk-version 2>/dev/null)"
sdk_root="${BEARBROWSER_SDK_ROOT:-${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}/bearbrowser-macos-sdk}"
tarball="$sdk_root/MacOSX${sdk_ver}.sdk.tar.zst"
[ -f "$tarball" ] || { log "FATAL: expected tarball not found: $tarball"; exit 1; }
sha="$(shasum -a 512 "$tarball" | awk '{print $1}')"
log "SDK tarball: $tarball (sha512=${sha:0:16}...)"

# 2. Push to zot as an OCI artifact, tagged by SDK version, with the sha512 as an
#    annotation for verification/pinning.
ref="${ZOT}/${repo_path}:${sdk_ver}"
log "pushing -> $ref"
( cd "$sdk_root" && oras push "$ref" \
    --artifact-type application/vnd.bearbrowser.macos-sdk \
    --annotation "org.sourceos.bearbrowser.sdk.version=${sdk_ver}" \
    --annotation "org.sourceos.bearbrowser.sdk.sha512=${sha}" \
    "MacOSX${sdk_ver}.sdk.tar.zst:application/zstd" ) \
  || { log "FATAL: oras push failed (check ZOT_REGISTRY + creds)"; exit 1; }

log "vendored macOS SDK ${sdk_ver} -> $ref"
log "point ci/bsys6-macos build at it:  --build-arg MACOS_SDK_REF=$ref"
