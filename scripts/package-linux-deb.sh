#!/usr/bin/env bash
set -euo pipefail

runtime_tree="${BEARBROWSER_LINUX_RUNTIME_TREE:-build/linux/runtime-tree}"
out_dir="${BEARBROWSER_DIST_DIR:-dist/linux}"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
arch="${BEARBROWSER_DEB_ARCH:-amd64}"

usage() {
  cat <<'USAGE'
Usage: package-linux-deb [--runtime-tree DIR] [--version VERSION] [--arch ARCH] [--out-dir DIR]

Packages a prepared BearBrowser Linux runtime tree into a Debian package.
Requires dpkg-deb.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --runtime-tree)
      runtime_tree="${2:?missing runtime tree}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
      shift 2
      ;;
    --arch)
      arch="${2:?missing arch}"
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

if ! command -v dpkg-deb >/dev/null 2>&1; then
  echo "ERROR: dpkg-deb is required to build deb packages" >&2
  exit 2
fi

if [ ! -d "$runtime_tree" ]; then
  echo "ERROR: runtime tree missing: $runtime_tree" >&2
  exit 64
fi

pkg_root="build/linux/deb-root"
rm -rf "$pkg_root"
mkdir -p "$pkg_root/DEBIAN"
cp -R "$runtime_tree/." "$pkg_root/"

cat > "$pkg_root/DEBIAN/control" <<EOF
Package: bearbrowser
Version: $version
Section: web
Priority: optional
Architecture: $arch
Maintainer: SourceOS <maintainers@sourceos.dev>
Homepage: https://github.com/SourceOS-Linux/BearBrowser
Description: SourceOS governed browser for humans and agents
 BearBrowser is a SourceOS governed browser with human-secure and agent-runtime profiles.
EOF

mkdir -p "$out_dir"
artifact="$out_dir/bearbrowser_${version}_${arch}.deb"
dpkg-deb --build "$pkg_root" "$artifact"
sha256="$(shasum -a 256 "$artifact" | awk '{print $1}')"

echo "deb: $artifact"
echo "SHA256: $sha256"
