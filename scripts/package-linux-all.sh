#!/usr/bin/env bash
set -euo pipefail

runtime_tree="${BEARBROWSER_LINUX_RUNTIME_TREE:-build/linux/runtime-tree}"
profile="${BEARBROWSER_PROFILE:-human-secure}"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
out_dir="${BEARBROWSER_DIST_DIR:-dist/linux}"

usage() {
  cat <<'USAGE'
Usage: package-linux-all [--runtime-tree DIR] [--profile PROFILE] [--version VERSION] [--out-dir DIR]

Runs all available BearBrowser Linux packagers against a prepared runtime tree.
Missing optional packaging tools are reported and skipped.
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

if [ ! -d "$runtime_tree" ]; then
  echo "ERROR: runtime tree missing: $runtime_tree" >&2
  echo "Lane 13 must produce a real runtime tree before package-linux-all can build artifacts." >&2
  exit 64
fi

mkdir -p "$out_dir"

bash scripts/package-linux-tarball.sh --runtime-tree "$runtime_tree" --profile "$profile" --version "$version" --out-dir "$out_dir"

if command -v dpkg-deb >/dev/null 2>&1; then
  bash scripts/package-linux-deb.sh --runtime-tree "$runtime_tree" --version "$version" --out-dir "$out_dir"
else
  echo "skip: dpkg-deb not installed"
fi

if command -v rpmbuild >/dev/null 2>&1; then
  bash scripts/package-linux-rpm.sh --runtime-tree "$runtime_tree" --version "${version%%-*}" --out-dir "$out_dir"
else
  echo "skip: rpmbuild not installed"
fi

if command -v appimagetool >/dev/null 2>&1; then
  bash scripts/package-linux-appimage.sh --runtime-tree "$runtime_tree" --profile "$profile" --version "$version" --out-dir "$out_dir"
else
  echo "skip: appimagetool not installed"
fi

if command -v flatpak-builder >/dev/null 2>&1 && command -v flatpak >/dev/null 2>&1; then
  bash scripts/package-linux-flatpak.sh --out-dir "$out_dir"
else
  echo "skip: flatpak-builder/flatpak not installed"
fi

find "$out_dir" -maxdepth 1 -type f -print
