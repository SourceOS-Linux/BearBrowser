#!/usr/bin/env bash
set -euo pipefail

version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
dmg_path="${BEARBROWSER_DMG_PATH:-dist/macos/BearBrowser-${version}-macos-universal.dmg}"
cask_path="${BEARBROWSER_CASK_PATH:-packaging/homebrew/Casks/bearbrowser.rb}"

usage() {
  cat <<'USAGE'
Usage: update-homebrew-cask [--version VERSION] [--dmg PATH] [--cask PATH]

Updates the BearBrowser Homebrew Cask SHA and version after a signed/notarized DMG is produced.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      version="${2:?missing version}"
      shift 2
      ;;
    --dmg)
      dmg_path="${2:?missing dmg path}"
      shift 2
      ;;
    --cask)
      cask_path="${2:?missing cask path}"
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

if [ ! -f "$dmg_path" ]; then
  echo "ERROR: DMG not found: $dmg_path" >&2
  exit 64
fi

if [ ! -f "$cask_path" ]; then
  echo "ERROR: Cask not found: $cask_path" >&2
  exit 1
fi

sha256="$(shasum -a 256 "$dmg_path" | awk '{print $1}')"

python3 - "$cask_path" "$version" "$sha256" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
version = sys.argv[2]
sha = sys.argv[3]
text = path.read_text()
text = re.sub(r'version "[^"]+"', f'version "{version}"', text)
text = re.sub(r'sha256 (:no_check|"[a-fA-F0-9]+")', f'sha256 "{sha}"', text)
path.write_text(text)
PY

echo "Updated Cask: $cask_path"
echo "version=$version"
echo "sha256=$sha256"
