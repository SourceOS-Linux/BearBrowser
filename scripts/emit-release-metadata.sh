#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
upstream_ref="unknown"
out="build/release-metadata/bearbrowser-release-metadata.json"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

usage() {
  cat <<'USAGE'
Usage: emit-release-metadata [--profile human-secure|agent-runtime] [--upstream-ref REF] [--out PATH]

Emits BearBrowser release metadata required for binary artifact promotion.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      profile="${2:?missing profile}"
      shift 2
      ;;
    --upstream-ref)
      upstream_ref="${2:?missing upstream ref}"
      shift 2
      ;;
    --out)
      out="${2:?missing output path}"
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

mkdir -p "$(dirname "$out")"

revision="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
patch_hash="none"
if [ -d "$repo_root/patches" ] && find "$repo_root/patches" -type f -name '*.patch' | grep -q .; then
  patch_hash="$(find "$repo_root/patches" -type f -name '*.patch' -print0 | sort -z | xargs -0 cat | shasum -a 256 | awk '{print $1}')"
fi
policy_hash="$(shasum -a 256 "$repo_root/policy/bearbrowser-contract.yaml" | awk '{print $1}')"
mount_hash="none"
if [ -f "$repo_root/mounts/agent-browser-mounts.yaml" ]; then
  mount_hash="$(shasum -a 256 "$repo_root/mounts/agent-browser-mounts.yaml" | awk '{print $1}')"
fi

target_system="$(uname -s)-$(uname -m)"
build_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$out" <<EOF
{
  "product": "BearBrowser",
  "profile": "$profile",
  "upstreamRef": "$upstream_ref",
  "bearbrowserRevision": "$revision",
  "patchStackHash": "$patch_hash",
  "policyContractHash": "$policy_hash",
  "mountPlanHash": "$mount_hash",
  "targetSystem": "$target_system",
  "buildTimestamp": "$build_timestamp"
}
EOF

echo "Release metadata written: $out"
