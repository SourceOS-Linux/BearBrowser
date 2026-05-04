#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
cd "$repo_root"

bash scripts/bearbrowser-build-binary.sh --profile human-secure --ref latest --dry-run
bash scripts/bearbrowser-build-binary.sh --profile agent-runtime --ref latest --dry-run
bash scripts/verify-build-lane.sh

test -f build/release-metadata/bearbrowser-human-secure-release-metadata.json
test -f build/release-metadata/bearbrowser-agent-runtime-release-metadata.json

echo "BearBrowser binary build lane dry-run verified"
