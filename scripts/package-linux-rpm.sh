#!/usr/bin/env bash
set -euo pipefail

runtime_tree="${BEARBROWSER_LINUX_RUNTIME_TREE:-build/linux/runtime-tree}"
out_dir="${BEARBROWSER_DIST_DIR:-dist/linux}"
version="${BEARBROWSER_VERSION:-0.1.0}"
release="${BEARBROWSER_RPM_RELEASE:-0.overlay}"
arch="${BEARBROWSER_RPM_ARCH:-x86_64}"

usage() {
  cat <<'USAGE'
Usage: package-linux-rpm [--runtime-tree DIR] [--version VERSION] [--release RELEASE] [--arch ARCH] [--out-dir DIR]

Packages a prepared BearBrowser Linux runtime tree into an RPM package.
Requires rpmbuild.
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
    --release)
      release="${2:?missing release}"
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

if ! command -v rpmbuild >/dev/null 2>&1; then
  echo "ERROR: rpmbuild is required to build rpm packages" >&2
  exit 2
fi

if [ ! -d "$runtime_tree" ]; then
  echo "ERROR: runtime tree missing: $runtime_tree" >&2
  exit 64
fi

rpm_root="build/linux/rpmbuild"
rm -rf "$rpm_root"
mkdir -p "$rpm_root/BUILD" "$rpm_root/RPMS" "$rpm_root/SOURCES" "$rpm_root/SPECS" "$rpm_root/SRPMS" "$out_dir"

tarball="$rpm_root/SOURCES/bearbrowser-${version}.tar.gz"
tar -C "$runtime_tree" -czf "$tarball" .

cat > "$rpm_root/SPECS/bearbrowser.spec" <<EOF
Name: bearbrowser
Version: $version
Release: $release%{?dist}
Summary: SourceOS governed browser for humans and agents
License: MPL-2.0
URL: https://github.com/SourceOS-Linux/BearBrowser
BuildArch: $arch
Source0: bearbrowser-%{version}.tar.gz

%description
BearBrowser is a SourceOS governed browser with human-secure and agent-runtime profiles.

%prep
mkdir -p bearbrowser-root
tar -xzf %{SOURCE0} -C bearbrowser-root

%build

%install
mkdir -p %{buildroot}
cp -a bearbrowser-root/. %{buildroot}/

%files
/usr/bin/bearbrowser
/usr/lib/bearbrowser
/usr/share/applications/dev.sourceos.BearBrowser.desktop
/usr/share/metainfo/dev.sourceos.BearBrowser.metainfo.xml
/usr/share/icons/hicolor/scalable/apps/dev.sourceos.BearBrowser.svg
/usr/share/bearbrowser

%changelog
* Sun May 03 2026 SourceOS <maintainers@sourceos.dev> - $version-$release
- BearBrowser RPM package.
EOF

rpmbuild --define "_topdir $(pwd)/$rpm_root" -bb "$rpm_root/SPECS/bearbrowser.spec"
find "$rpm_root/RPMS" -type f -name '*.rpm' -exec cp {} "$out_dir/" \;

echo "RPM artifacts:"
find "$out_dir" -type f -name '*.rpm' -maxdepth 1 -print -exec shasum -a 256 {} \;
