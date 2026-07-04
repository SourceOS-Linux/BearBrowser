#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
profile="agent-runtime"
ref="latest"
metadata="$repo_root/build/release-metadata/bearbrowser-${profile}-release-metadata.json"

bash "$repo_root/scripts/check-build-environment.sh"
bash "$repo_root/scripts/verify-upstream-parity.sh"
bash "$repo_root/scripts/apply-sourceos-overlays.sh" --profile "$profile" --ref "$ref" --dry-run
bash "$repo_root/scripts/emit-release-metadata.sh" --profile "$profile" --upstream-ref "$ref" --out "$metadata"

test -f "$metadata"
python3 - "$metadata" <<'PY'
from pathlib import Path
import json
import sys
p = Path(sys.argv[1])
data = json.loads(p.read_text())
if data.get('product') != 'BearBrowser':
    raise SystemExit('ERROR: metadata product must be BearBrowser')
if data.get('profile') != 'agent-runtime':
    raise SystemExit('ERROR: metadata profile must be agent-runtime')
for key in ['upstreamRef', 'bearbrowserRevision', 'policyContractHash', 'targetSystem', 'buildTimestamp']:
    if not data.get(key):
        raise SystemExit(f'ERROR: metadata missing {key}')
print('ok: release metadata verified')
PY

echo "BearBrowser build lane verified"
