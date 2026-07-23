#!/usr/bin/env bash
# Packages a completed BearBrowser source build into a signed, settings-injected
# BearBrowser.app bundle ready for development use.
#
# Usage: bearbrowser-package-source-build [--workspace DIR] [--profile PROFILE]
#        [--out-dir DIR] [--version VERSION] [--skip-sign] [--skip-verify]
#
# The workspace is the extracted source directory produced by `make dir`,
# e.g. build/workspaces/human-secure-150.0.1-1/source/bearbrowser-150.0.1-1/
# The compiled app is expected at obj-*/dist/BearBrowser.app inside it.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"

workspace=""
profile="human-secure"
out_dir="build/macos-source"
version="${BEARBROWSER_VERSION:-150.0.1}"
skip_sign="false"
skip_verify="false"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-package-source-build [--workspace DIR] [--profile PROFILE]
                                         [--out-dir DIR] [--version VERSION]
                                         [--skip-sign] [--skip-verify]

Packages the obj-*/dist/BearBrowser.app from a completed mach build into a
fully-branded, settings-injected BearBrowser.app for development use.

Options:
  --workspace   Path to the bearbrowser-VERSION-RELEASE/ source directory.
                Default: auto-detect from build/workspaces/*/source/bearbrowser-*/
  --profile     human-secure | agent-runtime.  Default: human-secure.
  --out-dir     Output directory.  Default: build/macos-source (relative to repo root).
  --version     Version string for Info.plist.  Default: 150.0.1.
  --skip-sign   Skip ad-hoc code signature.
  --skip-verify Skip BearBrowser identity verifier.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace)  workspace="${2:?missing --workspace}"; shift 2 ;;
    --profile)    profile="${2:?missing --profile}"; shift 2 ;;
    --out-dir)    out_dir="${2:?missing --out-dir}"; shift 2 ;;
    --version)    version="${2:?missing --version}"; shift 2 ;;
    --skip-sign)  skip_sign="true"; shift ;;
    --skip-verify) skip_verify="true"; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$profile" in
  human-secure|agent-runtime) ;;
  *)
    echo "ERROR: invalid profile '$profile'. Expected human-secure or agent-runtime." >&2
    exit 1
    ;;
esac

# ── Auto-detect workspace ──────────────────────────────────────────────────────
if [ -z "$workspace" ]; then
  workspace="$(find "$repo_root/build/workspaces" -maxdepth 4 -name 'bearbrowser-*' -type d 2>/dev/null \
    | sort -V | tail -1)"
  if [ -z "$workspace" ]; then
    echo "ERROR: could not auto-detect source workspace. Run 'make dir' first or pass --workspace." >&2
    exit 1
  fi
  echo "auto-detected workspace: $workspace"
fi

if [ ! -d "$workspace" ]; then
  echo "ERROR: workspace not found: $workspace" >&2
  exit 64
fi

# ── Find the PACKAGED app (has omni.ja) from `mach package` ──────────────────
# We package the app produced by `mach package`, identified by omni.ja. This is
# the real packaged layout: chrome JARred into omni.ja, real files (no symlinks),
# binary in Contents/MacOS. omni.ja makes Firefox's IsPackagedBuild() true, which
# skips the developer-build content-sandbox path (MozillaDeveloperRepoPath) that
# MOZ_CRASHes on end-user machines. Run `./mach build && ./mach package` first.
built_app=""
while IFS= read -r candidate; do
  if [ -f "$candidate/Contents/Resources/omni.ja" ]; then built_app="$candidate"; break; fi
done < <(find "$workspace" -maxdepth 6 -name 'BearBrowser.app' -type d 2>/dev/null)
if [ -z "$built_app" ] || [ ! -d "$built_app" ]; then
  echo "ERROR: no PACKAGED BearBrowser.app (with Contents/Resources/omni.ja) found." >&2
  echo "Run './mach build && ./mach package' first — 'mach build' alone leaves a" >&2
  echo "dev tree of symlinks with no omni.ja, which is not shippable." >&2
  exit 1
fi

echo "BearBrowser source build packager"
echo "  workspace  : $workspace"
echo "  built app  : $built_app"
echo "  profile    : $profile"
echo "  version    : $version"
echo "  out_dir    : $out_dir"
echo

out_app="$repo_root/$out_dir/BearBrowser.app"
mkdir -p "$(dirname "$out_app")"

# ── Step 1: Copy the packaged app ─────────────────────────────────────────────
# The mach-package output is self-contained (real files, omni.ja) so a plain
# recursive copy is correct.
echo "[1/6] Copying packaged app..."
rm -rf "$out_app"
cp -R "$built_app" "$out_app"
echo "      $built_app → $out_app"

# ── Gate: must be a real packaged app (omni.ja) with zero dangling symlinks ───
# omni.ja is the packaged-build marker; its absence sends the content sandbox
# down the dev-build path that crashes on end-user machines. Dangling symlinks
# = a non-self-contained bundle (the /Users/runner/... defect). Fail on either.
echo "      verifying the packaged app..."
missing=""
for req in Contents/Resources/omni.ja Contents/Resources/browser/omni.ja; do
  [ -f "$out_app/$req" ] || missing="$missing $req"
done
if [ -n "$missing" ]; then
  echo "ERROR: packaged app missing required archives:$missing" >&2
  echo "The source was not a real 'mach package' output. Aborting." >&2
  exit 1
fi
dangling="$(find "$out_app" -type l ! -exec test -e {} \; -print 2>/dev/null | head -5)"
if [ -n "$dangling" ]; then
  echo "ERROR: the app contains dangling symlinks (not self-contained):" >&2
  echo "$dangling" | sed 's/^/  /' >&2
  exit 1
fi
echo "      OK — omni.ja present, no dangling symlinks."

# ── Step 2: Write BearBrowser Info.plist ──────────────────────────────────────
echo "[2/6] Writing BearBrowser Info.plist..."
info_template="$repo_root/packaging/macos/Info.plist.template"
if [ ! -f "$info_template" ]; then
  echo "ERROR: Info.plist template missing: $info_template" >&2
  exit 1
fi

python3 - "$info_template" "$out_app/Contents/Info.plist" "$version" <<'PY'
import sys, re
from pathlib import Path
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
version = sys.argv[3]
text = src.read_text()
# Replace placeholder version strings
text = re.sub(r'<string>0\.\d+\.\d+-[^<]+</string>', f'<string>{version}</string>', text)
dst.write_text(text)
print(f"      Info.plist written: {dst}")
PY

# ── Step 3: Install BearBrowser icon ─────────────────────────────────────────
echo "[3/6] Installing BearBrowser icon..."
icon_svg="$repo_root/branding/bearbrowser.svg"
if [ -f "$icon_svg" ]; then
  cp "$icon_svg" "$out_app/Contents/Resources/BearBrowser.svg"
  echo "      BearBrowser.svg installed"
else
  echo "      WARNING: $icon_svg not found — skipping icon"
fi

# ── Step 4: Inject profile settings ─────────────────────────────────────────
echo "[4/6] Injecting profile settings (profile=$profile)..."
profile_dir="$repo_root/settings/profiles/$profile"

if [ ! -d "$profile_dir" ]; then
  echo "ERROR: profile directory not found: $profile_dir" >&2
  exit 1
fi

# user.js -> browser/defaults/preferences/ (default-pref file).
# user.js uses user_pref(), which is ONLY valid in a profile's prefs.js — a
# default-pref file must use pref(). Convert so the prefs actually take effect.
pref_dest="$out_app/Contents/Resources/browser/defaults/preferences"
mkdir -p "$pref_dest"
if [ -f "$profile_dir/user.js" ]; then
  python3 "$script_dir/userjs-to-autoconfig.py" \
    "$profile_dir/user.js" "$pref_dest/bearbrowser-user.js" --profile "$profile"
  echo "      user.js → $pref_dest/bearbrowser-user.js (user_pref→pref)"
fi

# policies.json goes into distribution/
policy_dest="$out_app/Contents/Resources/distribution"
mkdir -p "$policy_dest"
if [ -f "$profile_dir/policies.json" ]; then
  # Strip inline // comments — Firefox rejects a commented policies.json.
  python3 "$script_dir/strip-json-comments.py" "$profile_dir/policies.json" "$policy_dest/policies.json"
  echo "      policies.json → $policy_dest/policies.json (comments stripped)"
fi

# BearStart new-tab wiring (macOS lane). Linux/Windows get this via the
# overlay-generated bearbrowser.cfg; on macOS the cfg is not emitted by the
# build (see the nightly-dmg manifest-relax step), so inject a minimal cfg here
# that only carries the AboutNewTab override, plus the autoconfig wiring prefs.
# Prefs themselves already ship via bearbrowser-user.js above — no duplication.
# NOTE: autoconfig .cfg files skip their FIRST line (must be a comment).
if [ -f "$repo_root/settings/start/bearstart-autoconfig.js" ]; then
  cp "$repo_root/settings/start/bearstart-autoconfig.js" \
    "$out_app/Contents/Resources/bearbrowser.cfg"
  # Autoconfig wiring must live in defaults/pref/ at the resources root — the
  # one loose default-pref dir packaged Firefox reads (enterprise-documented).
  wiring_dest="$out_app/Contents/Resources/defaults/pref"
  mkdir -p "$wiring_dest"
  cat > "$wiring_dest/local-settings.js" <<'EOF_BEARSTART_WIRING'
// BearBrowser autoconfig wiring — injected by bearbrowser-package-source-build.sh
pref("general.config.obscure_value", 0);
pref("general.config.filename", "bearbrowser.cfg");
pref("general.config.sandbox_enabled", false);
EOF_BEARSTART_WIRING
  echo "      bearstart-autoconfig.js → Contents/Resources/bearbrowser.cfg (new-tab wiring)"
fi

# ── Step 5: Ad-hoc sign ───────────────────────────────────────────────────────
echo "[5/6] Code signing..."
if [ "$skip_sign" = "true" ]; then
  echo "      skipping (--skip-sign)"
elif command -v codesign >/dev/null 2>&1; then
  # Strip quarantine first
  xattr -cr "$out_app" 2>/dev/null || true
  # Sign inner components depth-first, then outer bundle
  find "$out_app" \( -name '*.framework' -o -name '*.dylib' -o \( -name '*.app' -not -path "$out_app" \) \) \
    | sort -r | while read -r inner; do
    codesign --force --sign - "$inner" 2>/dev/null || true
  done
  codesign --force --sign - "$out_app" 2>&1 | grep -v "^$" | sed 's/^/      /' || {
    echo "      WARNING: outer bundle sign returned non-zero (may still run fine)"
  }
  echo "      ad-hoc signature applied"
else
  echo "      WARNING: codesign not found — skipping"
fi

# ── Step 6: Verify ───────────────────────────────────────────────────────────
echo "[6/6] Verifying BearBrowser identity..."
if [ "$skip_verify" = "true" ]; then
  echo "      skipping (--skip-verify)"
else
  bash "$script_dir/verify-macos-app.sh" --app "$out_app" --skip-signing 2>&1 | sed 's/^/      /'
fi

echo
echo "BearBrowser source build packaged."
echo "  App : $out_app"
echo
echo "To launch:"
echo "  open '$out_app'"
echo
echo "To test automation (agent-runtime profile):"
echo "  BEARBROWSER_MODE=agent-runtime bash scripts/bearbrowser-playwright.sh --url https://example.com"
