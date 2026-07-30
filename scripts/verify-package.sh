#!/usr/bin/env bash
# verify-package.sh <GRE_DIR> — assert the hardening actually LANDED in a build.
#
# Static, deterministic, no GUI: it inspects the packaged artifact. That matters
# because the failures we actually hit were packaging failures, not logic bugs —
# BearBlocker shipped with ZERO filter lists for weeks because FINAL_TARGET_FILES
# does not survive `mach package`, and nothing checked.
#
#   bash scripts/verify-package.sh /Applications/BearBrowser.app/Contents/Resources
#   bash scripts/verify-package.sh <linux-tarball-dir>/bearbrowser
#
# Exit non-zero on any failed assertion. Wire into CI after packaging.
set -uo pipefail
GRE="${1:?usage: verify-package.sh <GRE_DIR>}"
[ -d "$GRE" ] || { echo "not a directory: $GRE" >&2; exit 2; }
# Resolve to an ABSOLUTE path: the omni.ja extraction below cd's into a temp
# dir, so a relative $GRE would stop resolving there (it silently made the
# prefs assertion unrunnable — the permanently-red check anti-pattern).
GRE="$(cd "$GRE" && pwd)"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  🔴 $1"; FAIL=$((FAIL+1)); }
have(){ [ -s "$1" ]; }

echo "verifying package: $GRE"
echo
echo "— BearNet / start page (resource://bearstart) —"
have "$GRE/browser/bearstart/bearnet.html"          && ok "bearnet.html staged"          || no "bearnet.html MISSING"
have "$GRE/browser/bearstart/bearbrowser-start.html" && ok "start page staged"            || no "start page MISSING"
have "$GRE/browser/bearstart/cockpit-waiter.html"     && ok "cockpit-waiter staged"       || no "cockpit-waiter MISSING (cockpit new-tab will race)"

echo "— BearBlocker filter lists (the paper tiger that shipped empty) —"
for f in bearblocker-ads.txt bearblocker-privacy.txt; do
  if have "$GRE/browser/bearblocker/$f"; then
    n=$(wc -l < "$GRE/browser/bearblocker/$f" | tr -d ' ')
    [ "$n" -gt 10 ] && ok "$f staged ($n rules)" || no "$f staged but only $n lines — suspiciously empty"
  else
    no "$f MISSING — the ad/tracker blocker will load NOTHING"
  fi
done

echo "— autoconfig wiring —"
CFG=""
for c in "$GRE/bearbrowser.cfg" "$GRE/librewolf.cfg" "$GRE/../bearbrowser.cfg"; do
  [ -f "$c" ] && CFG="$c" && break
done
if [ -n "$CFG" ]; then
  grep -q 'setSubstitution("bearstart"'   "$CFG" && ok "resource://bearstart registered"   || no "bearstart substitution MISSING"
  grep -q 'setSubstitution("bearblocker"' "$CFG" && ok "resource://bearblocker registered" || no "bearblocker substitution MISSING"
  grep -q 'BearTrapMonitor'               "$CFG" && ok "BearTrap/BearWall started"          || no "BearTrapMonitor NOT started"
  grep -q 'capture-sidecar-bin'           "$CFG" && ok "sidecar launcher present"           || no "sidecar launcher MISSING"
else
  no "no autoconfig (.cfg) found — NONE of the runtime wiring is active"
fi

echo "— phone-home endpoints stripped from packaged prefs —"
GREP_TARGETS="incoming.telemetry.mozilla.org detectportal.firefox.com aus5.mozilla.org safebrowsing.googleapis.com"
# greprefs.js lives INSIDE omni.ja, not on disk — extract it, or this check can
# never pass and a permanently-red check is one everybody learns to ignore.
TMPP="$(mktemp -d)"; trap 'rm -rf "$TMPP"' EXIT
for oj in "$GRE/omni.ja" "$GRE/browser/omni.ja"; do
  [ -f "$oj" ] && (cd "$TMPP" && unzip -qq -o "$oj" 'greprefs.js' 'defaults/preferences/*' 2>/dev/null) || true
done
PREFS=$(find "$TMPP" -name 'greprefs.js' -o -name '*.js' -path '*defaults/preferences*' 2>/dev/null | head -4)
if [ -n "$PREFS" ]; then
  for host in $GREP_TARGETS; do
    if grep -qF "\"https://$host" $PREFS 2>/dev/null || grep -qF "\"http://$host" $PREFS 2>/dev/null; then
      no "endpoint still present in prefs: $host"
    else
      ok "endpoint stripped: $host"
    fi
  done
else
  no "could not locate packaged prefs to check"
fi

echo "— sidecar + geo assets —"
ls "$GRE"/sidecars/bearbrowser-capture-sidecar-bin* >/dev/null 2>&1 && ok "capture sidecar staged" || no "capture sidecar MISSING (BearNet ships offline)"
have "$GRE/geoip/dbip-city-lite.mmdb" && ok "city GeoIP staged" || no "city GeoIP MISSING (map cannot resolve locally)"

echo
echo "================ $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ] || { echo "PACKAGE VERIFICATION FAILED — do not ship this build."; exit 1; }
echo "package verified."
