#!/usr/bin/env bash
set -euo pipefail

manifest="packaging/linux/flatpak/dev.sourceos.BearBrowser.yaml"
out_dir="${BEARBROWSER_DIST_DIR:-dist/linux}"
repo_dir="build/linux/flatpak-repo"
branch="${BEARBROWSER_FLATPAK_BRANCH:-stable}"

usage() {
  cat <<'USAGE'
Usage: package-linux-flatpak [--manifest PATH] [--branch BRANCH] [--out-dir DIR]

Builds the BearBrowser Flatpak scaffold.
Requires flatpak-builder.

The manifest currently contains a placeholder command until Lane 13 provides the real browser binary.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --manifest)
      manifest="${2:?missing manifest}"
      shift 2
      ;;
    --branch)
      branch="${2:?missing branch}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?missing output dir}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v flatpak-builder >/dev/null 2>&1; then
  echo "ERROR: flatpak-builder is required to build Flatpak artifacts" >&2
  exit 2
fi

if [ ! -f "$manifest" ]; then
  echo "ERROR: Flatpak manifest missing: $manifest" >&2
  exit 1
fi

rm -rf build/linux/flatpak-build "$repo_dir"
mkdir -p "$out_dir"

flatpak-builder \
  --force-clean \
  --repo="$repo_dir" \
  --default-branch="$branch" \
  build/linux/flatpak-build \
  "$manifest"

bundle="$out_dir/BearBrowser-${branch}.flatpak"
flatpak build-bundle "$repo_dir" "$bundle" dev.sourceos.BearBrowser "$branch"
sha256="$(shasum -a 256 "$bundle" | awk '{print $1}')"

echo "Flatpak bundle: $bundle"
echo "SHA256: $sha256"
