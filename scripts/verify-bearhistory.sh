#!/usr/bin/env bash
set -euo pipefail

required=(
  docs/local-first-bearhistory.md
  schemas/bearhistory-event.v1.json
  schemas/bearhistory-sync-policy.v1.json
  examples/bearhistory-sync-policy.example.yaml
  examples/ops-history-browser-event.example.json
)

for path in "${required[@]}"; do
  if [ ! -f "$path" ]; then
    echo "ERROR: missing BearHistory artifact: $path" >&2
    exit 1
  fi
  echo "ok: $path"
done

python3 - <<'PY'
from pathlib import Path
import json
import yaml

for path in ['schemas/bearhistory-event.v1.json', 'schemas/bearhistory-sync-policy.v1.json', 'examples/ops-history-browser-event.example.json']:
    json.loads(Path(path).read_text())

policy = yaml.safe_load(Path('examples/bearhistory-sync-policy.example.yaml').read_text())
spec = policy['spec']
errors = []

if spec['opsHistoryBridge']['authority'] != 'PolicyFabric':
    errors.append('OpsHistory bridge authority must be PolicyFabric')
if spec['opsHistoryBridge']['exportHumanProfileByDefault'] is not False:
    errors.append('human profile export to OpsHistory must be false by default')
if spec['profiles']['humanSecure']['exportToOpsHistory'] is not False:
    errors.append('humanSecure exportToOpsHistory must be false')
if spec['profiles']['agentRuntime']['exportToOpsHistory'] is not True:
    errors.append('agentRuntime exportToOpsHistory must be true in example')
for profile_name, profile in spec['profiles'].items():
    if profile.get('secretMaterialPolicy') != 'denyExport':
        errors.append(f'{profile_name} secretMaterialPolicy must be denyExport')
if spec['deletionPriority']['enabled'] is not True:
    errors.append('deletion priority lane must be enabled')
if spec['deletionPriority']['requiresAcknowledgement'] is not True:
    errors.append('deletion priority lane must require acknowledgement')
if spec['deletionPriority'].get('includeTombstones') is not True:
    errors.append('deletion priority lane must include tombstones')

ops_event = json.loads(Path('examples/ops-history-browser-event.example.json').read_text())
if ops_event.get('profileMode') != 'agent-runtime':
    errors.append('OpsHistory example must use agent-runtime profile')
if ops_event.get('redacted') is not True:
    errors.append('OpsHistory example must be redacted')
for key in ['policyDecisionId', 'evidenceRef', 'workspaceId']:
    if not ops_event.get(key):
        errors.append(f'OpsHistory example missing {key}')

if errors:
    for error in errors:
        print(f'ERROR: {error}')
    raise SystemExit(1)

print('BearHistory policy artifacts verified')
PY
