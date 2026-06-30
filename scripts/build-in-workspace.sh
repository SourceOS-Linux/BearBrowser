#!/usr/bin/env bash
set -euo pipefail

profile="agent-runtime"
workspace=""
execute="false"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

usage() {
  cat <<USAGE
Usage: build-in-workspace.sh --workspace DIR [--profile agent-runtime|human-secure] [--execute]

Installs the profile mozconfig into the workspace source tree and runs the
LibreWolf (Firefox) mach build + package.

WARNING: --execute runs a full browser compile (hours, heavy CPU/RAM).
Without --execute this prints the planned commands and exits (dry run).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) workspace="${2:?}"; shift 2 ;;
    --profile)   profile="${2:?}"; shift 2 ;;
    --execute)   execute="true"; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[ -n "$workspace" ] || { echo "ERROR: --workspace required" >&2; exit 1; }
source_dir="$workspace/source"
[ -d "$source_dir" ] || { echo "ERROR: missing $source_dir (run apply-sourceos-overlays.sh first)" >&2; exit 1; }

mozconfig_src="$repo_root/mozconfig/${profile}.mozconfig"
[ -f "$mozconfig_src" ] || { echo "ERROR: missing mozconfig $mozconfig_src" >&2; exit 1; }

objdir="obj-bearbrowser-${profile}"

echo "BearBrowser compile step"
echo "  profile=$profile"
echo "  workspace=$workspace"
echo "  source=$source_dir"
echo "  mozconfig=$mozconfig_src"
echo "  objdir=$source_dir/$objdir"
echo "  execute=$execute"

planned() {
  echo "  + cp '$mozconfig_src' '$source_dir/.mozconfig'"
  echo "  + (cd '$source_dir' && ./mach --no-interactive bootstrap --application-choice browser)"
  echo "  + (cd '$source_dir' && ./mach build)"
  echo "  + (cd '$source_dir' && ./mach package)"
  echo "  + artifact: $source_dir/$objdir/dist/bearbrowser-*.tar.* (or .../dist/bin)"
}

if [ "$execute" != "true" ]; then
  echo "DRY RUN — planned commands:"
  planned
  echo "Re-run with --execute to perform the (expensive) compile."
  exit 0
fi

# --- real compile (only with --execute) ---
cp "$mozconfig_src" "$source_dir/.mozconfig"
cd "$source_dir"
export MOZBUILD_STATE_PATH="${MOZBUILD_STATE_PATH:-$workspace/.mozbuild}"
./mach --no-interactive bootstrap --application-choice browser
./mach build
./mach package

artifact="$(ls -1 "$objdir"/dist/*.tar.* 2>/dev/null | head -1 || true)"
if [ -n "$artifact" ]; then
  sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  echo "BUILD ARTIFACT: $artifact"
  echo "SHA256: $sha"
  # Append to release metadata if present
  meta="$repo_root/build/release-metadata/bearbrowser-${profile}-release-metadata.json"
  if [ -f "$meta" ]; then
    python3 - "$meta" "$artifact" "$sha" <<'PY'
import json, sys, os
meta, artifact, sha = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(meta))
d.setdefault("artifacts", []).append({
    "path": artifact, "sha256": sha, "name": os.path.basename(artifact),
})
json.dump(d, open(meta, "w"), indent=2)
print("Updated", meta)
PY
  fi
else
  echo "WARNING: no packaged artifact found under $objdir/dist/" >&2
fi
