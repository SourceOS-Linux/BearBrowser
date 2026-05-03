#!/usr/bin/env bash
set -euo pipefail

required=(
  docs/credential-broker.md
  policy/credential-broker-contract.yaml
  credential-broker/macos-backends.yaml
  credential-broker/linux-backends.yaml
)

for path in "${required[@]}"; do
  if [ ! -f "$path" ]; then
    echo "ERROR: missing credential broker file: $path" >&2
    exit 1
  fi
  echo "ok: $path"
done

python3 - <<'PY'
from pathlib import Path
import yaml

contract = yaml.safe_load(Path('policy/credential-broker-contract.yaml').read_text())
spec = contract['spec']
errors = []

if spec['storageModel'].get('browserOwnedPasswordVault') != 'disabledByDefault':
    errors.append('browserOwnedPasswordVault must be disabledByDefault')
if spec['storageModel'].get('browserOwnedPaymentVault') != 'disabledByDefault':
    errors.append('browserOwnedPaymentVault must be disabledByDefault')
if spec['humanSecure']['biometricUnlock'].get('browserHandlesBiometricSecrets') is not False:
    errors.append('browser must not handle biometric secrets')
if spec['agentRuntime'].get('inheritHumanCredentials') is not False:
    errors.append('agent-runtime must not inherit human credentials')
if spec['agentRuntime'].get('credentialExport') != 'denied':
    errors.append('agent-runtime credential export must be denied')
if spec['agentRuntime']['payments'].get('allowed') is not False:
    errors.append('agent-runtime payments must be false')
if spec['agentRuntime']['autofill'].get('allowed') is not False:
    errors.append('agent-runtime autofill must be false')
if spec['redaction'].get('eventPayloadSecrets') != 'forbidden':
    errors.append('event payload secrets must be forbidden')

for backend_file in ['credential-broker/macos-backends.yaml', 'credential-broker/linux-backends.yaml']:
    data = yaml.safe_load(Path(backend_file).read_text())
    bspec = data['spec']
    if bspec['agentRuntime'].get('inheritHumanCredentials') is not False:
        errors.append(f'{backend_file}: agent-runtime inheritHumanCredentials must be false')
    for backend in bspec.get('backends', []):
        if backend.get('browserOwnedVault') is not False:
            errors.append(f'{backend_file}: backend {backend.get("name")} must not be browser-owned vault')
        if backend.get('name') == 'LocalAuthentication' and backend.get('browserHandlesBiometricSecrets') is not False:
            errors.append(f'{backend_file}: LocalAuthentication must not expose biometric secrets to browser')

if errors:
    for error in errors:
        print(f'ERROR: {error}')
    raise SystemExit(1)

print('BearBrowser credential broker policy verified')
PY
