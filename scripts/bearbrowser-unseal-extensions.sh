#!/usr/bin/env bash
# Temporarily unseal a specific extension for installation in human-secure profile.
#
# Usage:
#   bearbrowser-unseal-extensions --extension-id <id> [--duration-minutes N] [--list]
#
# --extension-id <id>    Firefox extension ID to unseal (e.g. {446900e4-...} or name@domain)
# --duration-minutes N   Auto-reseal after N minutes. Default: 15. Use 0 for manual reseal only.
# --list                 Print allowlist-tier extensions from the registry and exit
# --reseal               Immediately reseal (restores backed-up policies.json)
#
# Only extensions with disposition "allowlist" in settings/extensions/registry.json can be
# unsealed. Blocked extensions cannot be unsealed via this script regardless of arguments.
#
# The script patches the live policies.json for the human-secure profile in-place, with
# a timestamped backup. BearBrowser must be restarted for the policy change to take effect.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICIES="$REPO_ROOT/settings/profiles/human-secure/policies.json"
BACKUP_DIR="$REPO_ROOT/settings/profiles/human-secure/.policy-backups"
REGISTRY="$REPO_ROOT/settings/extensions/registry.json"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 1
}

list_allowlist() {
  python3 - "$REGISTRY" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1]).read())
print(f"{'Extension':<45}{'ID':<55}{'Tier'}")
print("-" * 140)
for ext in data["extensions"]:
    if ext["disposition"] == "allowlist":
        print(f"{ext['name']:<45}{ext['id']:<55}{ext.get('allowlist_tier','')}")
PY
}

check_registry() {
  local ext_id="$1"
  python3 - "$REGISTRY" "$ext_id" <<'PY'
import json, sys
data = json.loads(open(sys.argv[1]).read())
target = sys.argv[2]
for ext in data["extensions"]:
    if ext["id"] == target:
        d = ext["disposition"]
        if d == "blocked":
            print(f"BLOCKED:{ext['rationale']}")
        elif d == "allowlist":
            print(f"ALLOWED:{ext['name']}")
        elif d == "native":
            print(f"NATIVE:{ext.get('native_replacement','')}")
        else:
            print(f"REVIEW:{ext.get('rationale','')}")
        sys.exit(0)
print("UNKNOWN:")
PY
}

patch_policies() {
  local ext_id="$1"
  local ext_name="$2"
  python3 - "$POLICIES" "$ext_id" "$ext_name" <<'PY'
import json, sys
from pathlib import Path

p = Path(sys.argv[1])
data = json.loads(p.read_text())
ext_id = sys.argv[2]
ext_name = sys.argv[3]

settings = data["policies"]["ExtensionSettings"]
settings[ext_id] = {
    "installation_mode": "normal_installed",
    "_unsealed_by": "bearbrowser-unseal-extensions",
    "_unsealed_name": ext_name,
}
p.write_text(json.dumps(data, indent=2) + "\n")
print(f"Patched ExtensionSettings: {ext_id} → normal_installed")
PY
}

restore_policies() {
  local backup="$1"
  if [ -f "$backup" ]; then
    cp "$backup" "$POLICIES"
    echo "Resealed: restored $POLICIES from backup."
  else
    echo "No backup found at $backup — cannot reseal automatically." >&2
    exit 1
  fi
}

# ── Parse args ────────────────────────────────────────────────────────────────

ext_id=""
duration=15
reseal=false

if [ $# -eq 0 ]; then usage; fi

while [ $# -gt 0 ]; do
  case "$1" in
    --extension-id) ext_id="${2:?--extension-id requires an argument}"; shift 2 ;;
    --duration-minutes) duration="${2:?--duration-minutes requires an argument}"; shift 2 ;;
    --list) list_allowlist; exit 0 ;;
    --reseal)
      latest_backup="$(ls -t "$BACKUP_DIR"/policies.json.*.bak 2>/dev/null | head -1 || true)"
      if [ -z "$latest_backup" ]; then
        echo "No backup found in $BACKUP_DIR" >&2; exit 1
      fi
      restore_policies "$latest_backup"
      exit 0
      ;;
    -h|--help) usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [ -z "$ext_id" ]; then
  echo "Error: --extension-id is required." >&2
  usage
fi

# ── Registry check ────────────────────────────────────────────────────────────

result="$(check_registry "$ext_id")"
status="${result%%:*}"
detail="${result#*:}"

case "$status" in
  BLOCKED)
    echo "Error: '$ext_id' is unconditionally blocked and cannot be unsealed." >&2
    echo "Reason: $detail" >&2
    exit 1
    ;;
  NATIVE)
    echo "Note: '$ext_id' has a native BearBrowser replacement: $detail"
    echo "The extension is unnecessary — native capability covers this use case."
    read -p "Proceed with unseal anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    ;;
  REVIEW)
    echo "Warning: '$ext_id' has not been fully evaluated (disposition: review)." >&2
    echo "Note: $detail" >&2
    read -p "Proceed with unseal anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    ;;
  UNKNOWN)
    echo "Warning: '$ext_id' is not in the BearBrowser extension registry." >&2
    echo "Installing unknown extensions weakens your security boundary." >&2
    read -p "Proceed with unseal anyway? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 0
    ;;
  ALLOWED)
    echo "Unsealing: $detail ($ext_id)"
    ;;
esac

# ── Backup current policies ───────────────────────────────────────────────────

mkdir -p "$BACKUP_DIR"
backup_file="$BACKUP_DIR/policies.json.$(date +%Y%m%dT%H%M%S).bak"
cp "$POLICIES" "$backup_file"
echo "Backup: $backup_file"

# ── Patch policies.json ───────────────────────────────────────────────────────

patch_policies "$ext_id" "${detail:-$ext_id}"

echo ""
echo "Extension unsealed. Restart BearBrowser for the policy to take effect."
echo "You can now install: $ext_id"

# ── Schedule reseal ───────────────────────────────────────────────────────────

if [ "$duration" -gt 0 ] 2>/dev/null; then
  echo ""
  echo "Auto-resealing in ${duration} minutes (PID $$)..."
  (
    sleep $(( duration * 60 ))
    restore_policies "$backup_file"
    echo "Extensions resealed. Restart BearBrowser to apply." | \
      osascript -e 'set t to do shell script "cat"' \
                -e 'display notification t with title "BearBrowser" subtitle "Extension seal restored"' 2>/dev/null || true
  ) &
  echo "Reseal job running in background (PID $!). To reseal immediately:"
  echo "  bash scripts/bearbrowser-unseal-extensions.sh --reseal"
else
  echo "Duration 0: manual reseal required."
  echo "When done, run: bash scripts/bearbrowser-unseal-extensions.sh --reseal"
fi
