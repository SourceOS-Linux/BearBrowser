#!/usr/bin/env bash
set -euo pipefail

runtime_tree="${BEARBROWSER_LINUX_RUNTIME_TREE:-build/linux/runtime-tree}"
out_dir="${BEARBROWSER_DIST_DIR:-dist/linux}"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
profile="${BEARBROWSER_PROFILE:-human-secure}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: package-linux-appimage [--runtime-tree DIR] [--profile PROFILE] [--version VERSION] [--out-dir DIR]

Packages a prepared BearBrowser Linux runtime tree into an AppImage.
Requires appimagetool.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime-tree)
      runtime_tree="${2:?missing runtime tree}"
      shift 2
      ;;
    --profile)
      profile="${2:?missing profile}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
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

if ! command -v appimagetool >/dev/null 2>&1; then
  echo "ERROR: appimagetool is required to build AppImage artifacts" >&2
  exit 2
fi

if [ ! -d "$runtime_tree" ]; then
  echo "ERROR: runtime tree missing: $runtime_tree" >&2
  echo "Run prepare-linux-runtime-tree after Lane 13 produces a real runtime." >&2
  exit 64
fi

appdir="build/linux/appimage/BearBrowser.AppDir"
rm -rf "$appdir"
mkdir -p "$appdir"
cp -R "$runtime_tree/." "$appdir/"

cp "$repo_root/packaging/linux/appimage/AppRun" "$appdir/AppRun"
chmod +x "$appdir/AppRun"
cp "$repo_root/packaging/linux/dev.sourceos.BearBrowser.desktop" "$appdir/dev.sourceos.BearBrowser.desktop"
cp "$repo_root/packaging/linux/appimage/dev.sourceos.BearBrowser.appdata.xml" "$appdir/dev.sourceos.BearBrowser.appdata.xml"
cp "$repo_root/branding/bearbrowser.svg" "$appdir/dev.sourceos.BearBrowser.svg"

mkdir -p "$out_dir"
artifact="$out_dir/BearBrowser-${profile}-${version}-linux.AppImage"
ARCH="$(uname -m)" appimagetool "$appdir" "$artifact"
sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"

echo "AppImage: $artifact"
echo "SHA256: $sha256"
