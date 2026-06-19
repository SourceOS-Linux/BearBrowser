#!/usr/bin/env bash
set -euo pipefail

# Full BearBrowser install for Fedora (including Fedora Asahi Remix on Apple Silicon).
# Builds the RPM from a prepared runtime tree, or installs a pre-built RPM if one is provided.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
arch="$(uname -m)"
version="${BEARBROWSER_VERSION:-0.1.0}"
release="${BEARBROWSER_RPM_RELEASE:-0.overlay}"
runtime_tree="${BEARBROWSER_LINUX_RUNTIME_TREE:-$repo_root/build/linux/runtime-tree}"
dist_dir="${BEARBROWSER_DIST_DIR:-$repo_root/dist/linux}"
prebuilt_rpm="${BEARBROWSER_PREBUILT_RPM:-}"
profile="${BEARBROWSER_PROFILE:-human-secure}"
skip_dnf="${BEARBROWSER_SKIP_DNF_INSTALL:-false}"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-install-fedora [--rpm PATH] [--runtime-tree DIR] [--version VERSION] [--profile PROFILE] [--skip-dnf]

Install BearBrowser on Fedora (including Fedora Asahi Remix on aarch64/Apple Silicon).

Options:
  --rpm           Path to a pre-built BearBrowser RPM. If omitted, build from --runtime-tree.
  --runtime-tree  Path to a prepared runtime tree (from prepare-linux-runtime-tree.sh). Default: build/linux/runtime-tree.
  --version       Package version string. Default: 0.1.0.
  --profile       BearBrowser profile: human-secure or agent-runtime. Default: human-secure.
  --skip-dnf      Stage the RPM but do not run dnf install.

Architecture is detected automatically (uname -m). Asahi Linux reports aarch64.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rpm)
      prebuilt_rpm="${2:?missing rpm path}"
      shift 2
      ;;
    --runtime-tree)
      runtime_tree="${2:?missing runtime tree}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
      shift 2
      ;;
    --profile)
      profile="${2:?missing profile}"
      shift 2
      ;;
    --skip-dnf)
      skip_dnf="true"
      shift
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

if [ "$(uname -s)" != "Linux" ]; then
  echo "ERROR: bearbrowser-install-fedora is for Linux (Fedora) only." >&2
  echo "For macOS, run: bash scripts/install-macos-app-launcher.sh" >&2
  exit 1
fi

if ! command -v rpm >/dev/null 2>&1; then
  echo "ERROR: rpm not found — this script targets Fedora/RPM-based systems." >&2
  exit 1
fi

echo "BearBrowser Fedora install"
echo "arch=$arch"
echo "version=$version"
echo "profile=$profile"

# ── Detect Asahi ──────────────────────────────────────────────────────────────
asahi=false
if grep -qi 'asahi\|apple silicon\|m1\|m2\|m3\|m4' /proc/cpuinfo 2>/dev/null \
   || grep -qi 'asahi' /etc/os-release 2>/dev/null \
   || [ "${arch}" = "aarch64" ]; then
  asahi=true
  echo "platform=fedora-asahi-aarch64"
fi

# ── Install build deps if needed ──────────────────────────────────────────────
if [ -z "$prebuilt_rpm" ] && ! command -v rpmbuild >/dev/null 2>&1; then
  echo "rpmbuild not found — installing rpm-build..."
  sudo dnf install -y rpm-build
fi

# ── Build RPM from runtime tree if no pre-built RPM provided ─────────────────
if [ -z "$prebuilt_rpm" ]; then
  if [ ! -d "$runtime_tree" ]; then
    echo ""
    echo "ERROR: runtime tree not found at: $runtime_tree"
    echo ""
    echo "The BearBrowser Gecko runtime has not been built yet."
    echo "Run the following to build it first:"
    echo "  bash scripts/bearbrowser-build-binary.sh --profile $profile"
    echo "  bash scripts/prepare-linux-runtime-tree.sh --input-dir <build-output> --profile $profile"
    echo ""
    echo "Once the runtime is ready, re-run this script."
    exit 64
  fi

  echo "Building RPM from runtime tree: $runtime_tree"
  export BEARBROWSER_LINUX_RUNTIME_TREE="$runtime_tree"
  export BEARBROWSER_DIST_DIR="$dist_dir"
  export BEARBROWSER_VERSION="$version"
  export BEARBROWSER_RPM_RELEASE="$release"
  export BEARBROWSER_RPM_ARCH="$arch"

  bash "$script_dir/package-linux-rpm.sh" \
    --runtime-tree "$runtime_tree" \
    --version "$version" \
    --release "$release" \
    --arch "$arch" \
    --out-dir "$dist_dir"

  prebuilt_rpm="$(find "$dist_dir" -maxdepth 1 -name "bearbrowser-${version}-*.${arch}.rpm" | sort | tail -1)"

  if [ -z "$prebuilt_rpm" ] || [ ! -f "$prebuilt_rpm" ]; then
    echo "ERROR: RPM build did not produce an expected artifact in $dist_dir" >&2
    exit 1
  fi

  echo "Built RPM: $prebuilt_rpm"
fi

echo "RPM: $prebuilt_rpm"

if [ "$skip_dnf" = "true" ]; then
  echo "Skipping dnf install (--skip-dnf)."
  echo "To install manually: sudo dnf install '$prebuilt_rpm'"
  exit 0
fi

# ── Install via dnf ───────────────────────────────────────────────────────────
echo "Installing BearBrowser via dnf..."
sudo dnf install -y "$prebuilt_rpm"

# ── Post-install desktop integration ─────────────────────────────────────────
echo "Updating desktop database..."
sudo update-desktop-database /usr/share/applications/ 2>/dev/null || true

echo "Updating icon cache..."
sudo gtk-update-icon-cache /usr/share/icons/hicolor/ 2>/dev/null || true

# Restore SELinux file contexts if SELinux is enforcing.
if command -v restorecon >/dev/null 2>&1; then
  echo "Restoring SELinux contexts..."
  sudo restorecon -RF /usr/lib/bearbrowser/ 2>/dev/null || true
  sudo restorecon -F /usr/bin/bearbrowser 2>/dev/null || true
fi

# Register as a web browser handler via xdg-mime.
if command -v xdg-mime >/dev/null 2>&1; then
  echo "Registering BearBrowser as a browser handler..."
  xdg-mime default dev.sourceos.BearBrowser.desktop x-scheme-handler/http || true
  xdg-mime default dev.sourceos.BearBrowser.desktop x-scheme-handler/https || true
  xdg-mime default dev.sourceos.BearBrowser.desktop text/html || true
fi

# Register with xdg-settings if available.
if command -v xdg-settings >/dev/null 2>&1; then
  xdg-settings set default-web-browser dev.sourceos.BearBrowser.desktop 2>/dev/null || true
fi

echo ""
echo "BearBrowser installed on Fedora${asahi:+ (Asahi/Apple Silicon)}."
echo "Launch: bearbrowser"
echo "Or from your application launcher: BearBrowser"
if [ "$asahi" = "true" ]; then
  echo ""
  echo "Asahi note: Wayland is recommended. If using X11/XWayland, set:"
  echo "  export MOZ_ENABLE_WAYLAND=1"
  echo "  export GDK_BACKEND=wayland"
fi
