#!/usr/bin/env bash
set -euo pipefail

bash scripts/bearbrowser-build-binary.sh --profile human-secure --ref latest --dry-run
bash scripts/bearbrowser-build-binary.sh --profile agent-runtime --ref latest --dry-run

test -f build/release-metadata/bearbrowser-human-secure-release-metadata.json
test -f build/release-metadata/bearbrowser-agent-runtime-release-metadata.json

echo "BearBrowser binary build lane dry-run verified"
