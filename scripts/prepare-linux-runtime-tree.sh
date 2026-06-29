#!/usr/bin/env bash
set -euo pipefail

profile="human-secure"
input_dir=""
out_dir="build/linux/runtime-tree"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: prepare-linux-runtime-tree --input-dir PATH [--profile human-secure|agent-runtime] [--out-dir DIR] [--version VERSION]

Stages a Linux BearBrowser runtime tree for package builders.

The input directory must contain a real BearBrowser browser runtime produced by Lane 13.
This script does not synthesize a fake browser binary.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-dir)
      input_dir="${2:?missing input dir}"
      shift 2
      ;;
    --profile)
      profile="${2:?missing profile}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:?missing output dir}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
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

case "$profile" in
  human-secure|agent-runtime) ;;
  *)
    echo "ERROR: invalid profile: $profile" >&2
    exit 1
    ;;
esac

if [ -z "$input_dir" ]; then
  echo "ERROR: --input-dir is required" >&2
  usage >&2
  exit 1
fi

if [ ! -d "$input_dir" ]; then
  echo "ERROR: input runtime directory not found: $input_dir" >&2
  echo "Lane 13 must produce the real browser runtime first." >&2
  exit 64
fi

rm -rf "$out_dir"
mkdir -p "$out_dir/usr/bin"
mkdir -p "$out_dir/usr/lib/bearbrowser"
mkdir -p "$out_dir/usr/share/applications"
mkdir -p "$out_dir/usr/share/metainfo"
mkdir -p "$out_dir/usr/share/icons/hicolor/scalable/apps"
mkdir -p "$out_dir/usr/share/bearbrowser/profile"
mkdir -p "$out_dir/usr/share/bearbrowser/policy"
mkdir -p "$out_dir/usr/share/bearbrowser/manifests"

cp -R "$input_dir/." "$out_dir/usr/lib/bearbrowser/"
cp "$repo_root/packaging/linux/dev.sourceos.BearBrowser.desktop" "$out_dir/usr/share/applications/"
cp "$repo_root/packaging/linux/dev.sourceos.BearBrowser.metainfo.xml" "$out_dir/usr/share/metainfo/"
cp "$repo_root/branding/bearbrowser.svg" "$out_dir/usr/share/icons/hicolor/scalable/apps/dev.sourceos.BearBrowser.svg"
cp -R "$repo_root/settings/profiles/$profile/." "$out_dir/usr/share/bearbrowser/profile/"
cp "$repo_root/policy/bearbrowser-contract.yaml" "$out_dir/usr/share/bearbrowser/policy/"
cp "$repo_root/policy/credential-broker-contract.yaml" "$out_dir/usr/share/bearbrowser/policy/"
cp "$repo_root/manifests/upstream.json" "$out_dir/usr/share/bearbrowser/manifests/"

cat > "$out_dir/usr/bin/bearbrowser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/lib/bearbrowser/bearbrowser "$@"
EOF
chmod +x "$out_dir/usr/bin/bearbrowser"

cat > "$out_dir/usr/share/bearbrowser/package-metadata.json" <<EOF
{
  "product": "BearBrowser",
  "profile": "$profile",
  "version": "$version",
  "appId": "dev.sourceos.BearBrowser"
}
EOF

echo "Prepared Linux runtime tree: $out_dir"
