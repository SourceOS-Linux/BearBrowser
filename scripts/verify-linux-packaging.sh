#!/usr/bin/env bash
set -euo pipefail

desktop="packaging/linux/dev.sourceos.BearBrowser.desktop"
metainfo="packaging/linux/dev.sourceos.BearBrowser.metainfo.xml"
icon="branding/bearbrowser.svg"

required=(
  "$desktop"
  "$metainfo"
  "$icon"
  "packaging/linux/flatpak/dev.sourceos.BearBrowser.yaml"
  "packaging/linux/appimage/AppRun"
  "packaging/linux/appimage/dev.sourceos.BearBrowser.appdata.xml"
  "packaging/linux/deb/control"
  "packaging/linux/rpm/bearbrowser.spec"
  "packaging/linux/sandbox/apparmor/bearbrowser-agent-runtime"
  "packaging/linux/sandbox/seccomp/bearbrowser-agent-runtime.json"
  "packaging/linux/sandbox/selinux/bearbrowser-agent-runtime.te"
)

for path in "${required[@]}"; do
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

python3 - <<'PY'
from pathlib import Path
import json
import xml.etree.ElementTree as ET

json.loads(Path('packaging/linux/sandbox/seccomp/bearbrowser-agent-runtime.json').read_text())
for xml_path in [
    Path('packaging/linux/dev.sourceos.BearBrowser.metainfo.xml'),
    Path('packaging/linux/appimage/dev.sourceos.BearBrowser.appdata.xml'),
]:
    root = ET.parse(xml_path).getroot()
    component_id = root.findtext('id')
    name = root.findtext('name')
    if component_id != 'dev.sourceos.BearBrowser':
        raise SystemExit(f'ERROR: unexpected AppStream id in {xml_path}: {component_id}')
    if name != 'BearBrowser':
        raise SystemExit(f'ERROR: unexpected AppStream name in {xml_path}: {name}')
print('ok: structured metadata identity')
PY

if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$desktop"
  echo "ok: desktop-file-validate"
else
  echo "info: desktop-file-validate not installed; structural check only"
fi

if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$metainfo"
  xmllint --noout packaging/linux/appimage/dev.sourceos.BearBrowser.appdata.xml
  echo "ok: xmllint"
else
  echo "info: xmllint not installed; XML parser check skipped"
fi

echo "BearBrowser Linux packaging verified"
