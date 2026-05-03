#!/usr/bin/env bash
set -euo pipefail

desktop="packaging/linux/dev.sourceos.BearBrowser.desktop"
metainfo="packaging/linux/dev.sourceos.BearBrowser.metainfo.xml"
icon="branding/bearbrowser.svg"

for path in "$desktop" "$metainfo" "$icon"; do
  if [ ! -f "$path" ]; then
    echo "ERROR: missing Linux packaging file: $path" >&2
    exit 1
  fi
  echo "ok: $path"
done

if grep -RIE 'LibreWolf|librewolf|Libre Wolf' packaging/linux branding/bearbrowser.svg; then
  echo "ERROR: upstream product branding found in Linux product surface" >&2
  exit 1
fi

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$desktop"
  echo "ok: desktop-file-validate"
else
  echo "info: desktop-file-validate not installed; structural check only"
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$metainfo"
  echo "ok: xmllint"
else
  echo "info: xmllint not installed; XML parser check skipped"
fi

python3 - <<'PY'
from pathlib import Path
import xml.etree.ElementTree as ET

metainfo = Path('packaging/linux/dev.sourceos.BearBrowser.metainfo.xml')
root = ET.parse(metainfo).getroot()
component_id = root.findtext('id')
name = root.findtext('name')
if component_id != 'dev.sourceos.BearBrowser':
    raise SystemExit(f'ERROR: unexpected AppStream id: {component_id}')
if name != 'BearBrowser':
    raise SystemExit(f'ERROR: unexpected AppStream name: {name}')
print('ok: AppStream identity')
PY

echo "BearBrowser Linux packaging verified"
