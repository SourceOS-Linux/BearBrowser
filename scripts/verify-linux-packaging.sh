#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
cd "$repo_root"

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
  "packaging/linux/release-plan.yaml"
  "packaging/linux/sandbox/apparmor/bearbrowser-agent-runtime"
  "packaging/linux/sandbox/seccomp/bearbrowser-agent-runtime.json"
  "packaging/linux/sandbox/selinux/bearbrowser-agent-runtime.te"
  "scripts/prepare-linux-runtime-tree.sh"
  "scripts/package-linux-tarball.sh"
  "scripts/package-linux-deb.sh"
  "scripts/package-linux-rpm.sh"
  "scripts/package-linux-appimage.sh"
  "scripts/package-linux-flatpak.sh"
  "scripts/package-linux-all.sh"
)

for path in "${required[@]}"; do
  if [ ! -f "$path" ]; then
    echo "ERROR: missing Linux packaging file: $path" >&2
    exit 1
  fi
  echo "ok: $path"
done

bash -n scripts/prepare-linux-runtime-tree.sh
bash -n scripts/package-linux-tarball.sh
bash -n scripts/package-linux-deb.sh
bash -n scripts/package-linux-rpm.sh
bash -n scripts/package-linux-appimage.sh
bash -n scripts/package-linux-flatpak.sh
bash -n scripts/package-linux-all.sh

if grep -RIE 'LibreWolf|librewolf|Libre Wolf' packaging/linux branding/bearbrowser.svg; then
  echo "ERROR: upstream product branding found in Linux product surface" >&2
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import json
import xml.etree.ElementTree as ET
import yaml

json.loads(Path('packaging/linux/sandbox/seccomp/bearbrowser-agent-runtime.json').read_text())
release_plan = yaml.safe_load(Path('packaging/linux/release-plan.yaml').read_text())
if release_plan['spec']['product'] != 'BearBrowser':
    raise SystemExit('ERROR: Linux release plan product must be BearBrowser')
if release_plan['spec']['appId'] != 'dev.sourceos.BearBrowser':
    raise SystemExit('ERROR: Linux release plan appId must be dev.sourceos.BearBrowser')
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
