#!/usr/bin/env bash
# MIT License
# Copyright (c) 2026 @mdheller
#
# bearbrowser-install-extensions.sh — Install packed .xpi extensions into a
# BearBrowser.app bundle and wire them into policies.json as force-installed
# enterprise extensions.
#
# This script runs AFTER bearbrowser-pack-extensions.sh has produced .xpi files
# in build/extensions/ and AFTER the overlay build's profile injection step has
# written distribution/policies.json.  It:
#
#   1. Creates <app>/Contents/Resources/distribution/extensions/
#   2. Copies .xpi files from build/extensions/ into that directory
#   3. Merges Extension and ExtensionSettings policies into the existing
#      policies.json (or creates one if absent), preserving all other policies.
#
# The force_installed installation_mode causes Firefox/LibreWolf to install the
# extension silently on first run without any user prompt, even when the wildcard
# ExtensionSettings blocks other installs.
#
# Usage:
#   ./scripts/bearbrowser-install-extensions.sh [/path/to/BearBrowser.app]
#
# Arguments:
#   /path/to/BearBrowser.app    App bundle to install into.
#                               Default: /Applications/BearBrowser.app
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="${1:-/Applications/BearBrowser.app}"
XPI_SRC="$REPO/build/extensions"

if [ ! -d "$APP" ]; then
  echo "ERROR: app bundle not found: $APP" >&2
  exit 64
fi

if [ ! -d "$XPI_SRC" ]; then
  echo "ERROR: packed extensions directory not found: $XPI_SRC" >&2
  echo "Run bearbrowser-pack-extensions.sh first." >&2
  exit 1
fi

DIST_DIR="$APP/Contents/Resources/distribution"
EXT_DIR="$DIST_DIR/extensions"
POLICIES_JSON="$DIST_DIR/policies.json"

mkdir -p "$EXT_DIR"

echo "bearbrowser-install-extensions: installing into $APP"

# ── Step 1: Copy .xpi files ─────────────────────────────────────────────────
installed_ids=()
for xpi in "$XPI_SRC"/*.xpi; do
  if [ ! -f "$xpi" ]; then
    continue
  fi
  xpi_name="$(basename "$xpi")"
  cp "$xpi" "$EXT_DIR/$xpi_name"
  # Derive gecko ID from filename (strip .xpi)
  gecko_id="${xpi_name%.xpi}"
  installed_ids+=("$gecko_id")
  echo "  copied: $xpi_name → distribution/extensions/"
done

if [ "${#installed_ids[@]}" -eq 0 ]; then
  echo "  WARNING: no .xpi files found in $XPI_SRC" >&2
  exit 0
fi

# ── Step 2: Merge extension policies into policies.json ──────────────────────
# Absolute install URL paths used in the policy (the app must live at $APP at
# runtime for file:// URLs to resolve; for build-time bundling they are
# relative to the bundle so we compute the canonical path).
# The bundle's canonical install location is the path the user has the app at.
# We write paths relative to the bundle root using a placeholder and let the
# policy mergeread from the distribution/extensions/ dir which is always a
# sibling of the policies.json file.
#
# Firefox policy: install_url in ExtensionSettings must be an https:// or
# file:// URL.  For bundled local .xpi files the file:// URL must point to
# where the app is installed.  We write the canonical /Applications path here;
# if the app lives elsewhere the admin should re-run this script with the
# correct APP path.

python3 - "$POLICIES_JSON" "$EXT_DIR" "${installed_ids[@]}" <<'PY'
import json, sys, os, pathlib

policies_path = sys.argv[1]
ext_dir = sys.argv[2]
gecko_ids = sys.argv[3:]

# Load existing policies.json if present
if os.path.exists(policies_path):
    with open(policies_path, "r", encoding="utf-8") as f:
        doc = json.load(f)
else:
    doc = {}

policies = doc.setdefault("policies", {})

# Build the Install list and ExtensionSettings entries
install_urls = []
ext_settings = {}
for gid in gecko_ids:
    xpi_name = f"{gid}.xpi"
    # Compute the file:// URL.  At runtime the .app lives wherever the user
    # installed it; the ext_dir argument is the absolute path inside the bundle
    # as it sits on disk right now.  Use that path so the URL is accurate for
    # the current install location.
    xpi_path = os.path.realpath(os.path.join(ext_dir, xpi_name))
    xpi_url = pathlib.Path(xpi_path).as_uri()
    install_urls.append(xpi_url)
    ext_settings[gid] = {
        "installation_mode": "force_installed",
        "install_url": xpi_url,
    }

# Merge — preserve any pre-existing Extensions.Install entries
existing_install = (
    policies.get("Extensions", {}).get("Install", [])
)
# Deduplicate: remove stale entries for the same gecko IDs, then re-add
existing_install = [
    u for u in existing_install
    if not any(gid in u for gid in gecko_ids)
]
existing_install.extend(install_urls)

policies.setdefault("Extensions", {})["Install"] = existing_install

# Merge ExtensionSettings: keep existing entries, overlay our force_installed
existing_ext_settings = policies.setdefault("ExtensionSettings", {})
existing_ext_settings.update(ext_settings)

with open(policies_path, "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"  policies.json updated: {policies_path}")
for gid in gecko_ids:
    print(f"    force_installed: {gid}")
PY

echo "bearbrowser-install-extensions: done (${#installed_ids[@]} extension(s) installed)"
