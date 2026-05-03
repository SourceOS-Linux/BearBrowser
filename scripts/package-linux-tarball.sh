#!/usr/bin/env bash
set -euo pipefail

runtime_tree="${BEARBROWSER_LINUX_RUNTIME_TREE:-build/linux/runtime-tree}"
out_dir="${BEARBROWSER_DIST_DIR:-dist/linux}"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
profile="${BEARBROWSER_PROFILE:-human-secure}"

usage() {
  cat <<'USAGE'
Usage: package-linux-tarball [--runtime-tree DIR] [--profile PROFILE] [--version VERSION] [--out-dir DIR]

Packages a prepared BearBrowser Linux runtime tree into a tarball.
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
  exit 64
fi

mkdir -p "$out_dir"
artifact="$out_dir/BearBrowser-${profile}-${version}-linux.tar.gz"
tar -C "$runtime_tree" -czf "$artifact" .
sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"

echo "Tarball: $artifact"
echo "SHA256: $sha256"
