#!/usr/bin/env bash
# verify-brand-strings.sh — prevent regressions of the brand-string sweep.
#
# Enumerates user-visible or shipped files (RING 1 + RING 2 + RING 3 from the
# audit) and grep-blocks any Firefox / LibreWolf / Mozilla product-name leaks
# that would show up in:
#   - the GitHub README (marketing)
#   - `apt show`, `winget show`, `snap info`, `rpm -qi` (package metadata)
#   - Console / DevTools strings a user opens
#
# EXCLUDED (kept as legal attribution / technical fact — not leaks):
#   - hostname strings the monitor blocks by name (aus5.mozilla.org, etc.)
#   - XPCOM contract-ids ("@mozilla.org/binaryinputstream;1")
#   - extension IDs (react-devtools@mozilla.org, firefox@tampermonkey.net)
#   - the MPL 2.0 copyright header on every .sys.mjs
#   - gecko-patches/ (patches ARE against Firefox source; naming is correct)
#   - packaging/chocolatey/legal/LICENSE.txt (MPL requires attribution)
#   - packaging/RELEASE.md "Source: ... commit ..." lines (provenance)
#   - README.md's meta-policy statement about provenance names being allowed
#
# Exits non-zero on any regression. Wire into linux-packaging or a new
# workflow so a PR that reintroduces one of the sweep's targets fails.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAIL=0
report() { echo "  🔴 $1"; FAIL=$((FAIL+1)); }
ok()     { echo "  ✅ $1"; }

echo "verify-brand-strings: checking $REPO"

# ─ Files that must not contain any of these words ─
# The list mirrors what the audit landed. If a bug-class recurs the fix is a
# new line here, not more docs.
BANNED_IN_USER_VISIBLE='(Firefox 150 fork|LibreWolf-mirror|Firefox ETP strict|Firefox native HTTPS-only|Firefox layout\.css|Firefox Downloads|Firefox ESR|LibreWolf-derived|built on Firefox|Mozilla BearBrowser|Firefox-ESR fallback|firefox'"'"'s download manager)'

# Individual files (bounded scope — everything on the sweep's punch list)
FILES=(
  "README.md"
  "settings/actors/BearCaptureParent.sys.mjs"
  "settings/extensions/registry.json"
  "packaging/linux/deb/control"
  "packaging/linux/rpm/bearbrowser.spec"
  "packaging/linux/snap/snapcraft.yaml"
  "packaging/linux/binary-source.env"
  "packaging/chocolatey/README.md"
  "packaging/RELEASE.md"
  "packaging/oci/README.md"
  "packaging/winget/manifests/s/SourceOS/BearBrowser/150.0.1/SourceOS.BearBrowser.locale.en-US.yaml"
)

for f in "${FILES[@]}"; do
  P="$REPO/$f"
  if [ ! -f "$P" ]; then
    report "$f MISSING (expected on the sweep list — was it renamed?)"
    continue
  fi
  HIT=$(grep -nE "$BANNED_IN_USER_VISIBLE" "$P" 2>/dev/null || true)
  if [ -n "$HIT" ]; then
    report "$f contains banned brand leak(s):"
    echo "$HIT" | sed 's/^/       /'
  else
    ok "$f clean"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "brand-string sweep: OK"
  exit 0
fi
echo "brand-string sweep: $FAIL file(s) regressed"
exit 1
