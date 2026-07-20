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

# ── Find the built app in obj-* ───────────────────────────────────────────────
# The dev app that `mach build` produces. Its chrome/resources are symlinks into
# the objdir/srcdir (and there is no omni.ja) — but those targets EXIST here at
# package time, so we dereference them (cp -RL below) into a self-contained,
# runnable loose-chrome app. (This is the layout `mach run` uses; no omni.ja
# needed. We avoid `mach package` because its strict manifest requires fork
# hardening files our build doesn't emit in-tree.)
built_app="$(find "$workspace" -maxdepth 3 -path '*/obj-*/dist/BearBrowser.app' -type d 2>/dev/null | head -1)"
if [ -z "$built_app" ] || [ ! -d "$built_app" ]; then
  echo "ERROR: BearBrowser.app not found in $workspace/obj-*/dist/" >&2
  echo "Run 'make build' (or cd <workspace> && ./mach build) first." >&2
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

# ── Step 1: Copy the built app (DEREFERENCE symlinks) ─────────────────────────
# cp -RL follows every symlink and copies the real file CONTENTS. The dev app's
# resources are symlinks into the objdir/srcdir which exist right now, so this
# yields a fully self-contained bundle. (Plain `cp -R` copied the *links*, which
# dangled the moment the DMG left the build machine — the crash we shipped.)
echo "[1/6] Copying built app (dereferencing symlinks)..."
rm -rf "$out_app"
# Tolerate per-file cp errors (a stray broken source link shouldn't abort the
# whole copy); the self-contained gate below is the real completeness check.
cp -RL "$built_app" "$out_app" 2>/tmp/bb-cp-errs.txt \
  || echo "      note: cp -RL reported some errors (see below); the gate will verify completeness"
[ -s /tmp/bb-cp-errs.txt ] && sed 's/^/        cp: /' /tmp/bb-cp-errs.txt | head -10
echo "      $built_app → $out_app"

# ── Gate: the copied app must be self-contained + have its chrome ─────────────
# After cp -RL there must be ZERO dangling symlinks, and the chrome must be
# present (chrome.manifest for the loose layout, or omni.ja if ever packaged).
# This is the exact defect that shipped a crashing DMG (dangling links into
# /Users/runner/... + no chrome → ServiceWorkerRegistrar::ProfileStarted SIGSEGV).
echo "      verifying the copied app is self-contained..."
if [ ! -f "$out_app/Contents/Resources/chrome.manifest" ] \
   && [ ! -f "$out_app/Contents/Resources/omni.ja" ]; then
  echo "ERROR: no chrome in the app (neither chrome.manifest nor omni.ja present)." >&2
  echo "The source was not a complete build. Aborting." >&2
  exit 1
fi
dangling="$(find "$out_app" -type l ! -exec test -e {} \; -print 2>/dev/null | head -5)"
if [ -n "$dangling" ]; then
  echo "ERROR: the app still contains dangling symlinks (cp -RL should have" >&2
  echo "dereferenced them — a target was missing at package time):" >&2
  echo "$dangling" | sed 's/^/  /' >&2
  exit 1
fi
echo "      OK — chrome present, no dangling symlinks."

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
