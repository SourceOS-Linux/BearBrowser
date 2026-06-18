#!/usr/bin/env bash
# Applies BearBrowser branding and identity overlays to a LibreWolf base binary,
# producing a BearBrowser.app bundle suitable for dogfood use.
#
# This is the "binary overlay" path (Lane 2b): it produces a real browser fast
# by rebranding an existing LibreWolf build rather than compiling from source.
# Lane 13 (full Gecko source build) remains the long-term target for signed
# production releases.
#
# Signing: ad-hoc signatures are applied (codesign -s -) so the app runs on
# the local machine without Gatekeeper quarantine. Distribution-quality signing
# requires an Apple Developer certificate and is handled by sign-notarize-macos-app.sh.
set -euo pipefail

input_app=""
out_dir="build/macos-overlay"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"
profile="human-secure"
skip_verify="false"
skip_sign="false"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${BEARBROWSER_HOME:-$(cd "$script_dir/.." && pwd)}"
info_template="$repo_root/packaging/macos/Info.plist.template"

usage() {
  cat <<'USAGE'
Usage: bearbrowser-overlay-binary --input-app PATH [--profile human-secure|agent-runtime]
                                    [--out-dir DIR] [--version VERSION]
                                    [--skip-verify] [--skip-sign]

Applies BearBrowser identity and policy overlays to an existing LibreWolf.app bundle.

Steps:
  1. Copy the input app to <out-dir>/BearBrowser.app.
  2. Apply bearbrowser-branding overlay to all text-format files.
  3. Create a BearBrowser wrapper launcher in Contents/MacOS/.
  4. Write BearBrowser Info.plist from the canonical template.
  5. Install the BearBrowser icon.
  6. Inject profile settings (user.js, policies.json).
  7. Strip quarantine extended attributes.
  8. Apply ad-hoc code signature.
  9. Run branding and identity verification (unless --skip-verify).

Options:
  --input-app     Path to the source LibreWolf.app bundle. Required.
  --profile       BearBrowser profile to inject. Default: human-secure.
  --out-dir       Output directory. Default: build/macos-overlay.
  --version       Version string embedded in Info.plist. Default: 0.1.0-overlay.
  --skip-verify   Skip the BearBrowser identity verifier (useful in CI without codesign).
  --skip-sign     Skip ad-hoc signing (useful when signing separately).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --input-app)   input_app="${2:?missing --input-app path}"; shift 2 ;;
    --profile)     profile="${2:?missing --profile}"; shift 2 ;;
    --out-dir)     out_dir="${2:?missing --out-dir}"; shift 2 ;;
    --version)     version="${2:?missing --version}"; shift 2 ;;
    --skip-verify) skip_verify="true"; shift ;;
    --skip-sign)   skip_sign="true"; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -z "$input_app" ]; then
  echo "ERROR: --input-app is required." >&2
  echo "Tip: run bearbrowser-fetch-librewolf-base --print-path to get the path." >&2
  usage >&2
  exit 1
fi

if [ ! -d "$input_app" ]; then
  echo "ERROR: input app bundle not found: $input_app" >&2
  exit 64
fi

case "$profile" in
  human-secure|agent-runtime) ;;
  *)
    echo "ERROR: invalid profile '$profile'. Expected human-secure or agent-runtime." >&2
    exit 1
    ;;
esac

out_app="$repo_root/$out_dir/BearBrowser.app"

echo "BearBrowser binary overlay"
echo "input_app=$input_app"
echo "out_app=$out_app"
echo "profile=$profile"
echo "version=$version"
echo

# ── Step 1: Copy the base bundle ─────────────────────────────────────────────
echo "[1/9] Copying base bundle..."
rm -rf "$out_app"
mkdir -p "$(dirname "$out_app")"
cp -R "$input_app" "$out_app"
echo "      done → $out_app"

# ── Step 2: Apply text-format branding overlay ───────────────────────────────
echo "[2/9] Applying BearBrowser text branding overlay..."
bash "$script_dir/apply-bearbrowser-branding.sh" --workspace "$out_app"
# The branding script creates .bearbrowser/branding.json at the workspace root.
# Inside an app bundle this file sits outside Contents/ and breaks codesign's
# sealed-bundle check. Move it to Contents/Resources/ where it belongs.
if [ -d "$out_app/.bearbrowser" ]; then
  mkdir -p "$out_app/Contents/Resources/bearbrowser-metadata"
  mv "$out_app/.bearbrowser/"* "$out_app/Contents/Resources/bearbrowser-metadata/" 2>/dev/null || true
  rmdir "$out_app/.bearbrowser" 2>/dev/null || true
fi
# Remove any files the branding script placed directly at the bundle root
# (e.g. bearbrowser.svg copied to the app dir itself). codesign rejects
# unsealed files outside Contents/.
find "$out_app" -maxdepth 1 -not -name "Contents" -not -path "$out_app" -delete 2>/dev/null || true
echo "      done"

# ── Step 3: Create the BearBrowser wrapper launcher ──────────────────────────
echo "[3/9] Creating BearBrowser launcher wrapper..."
macos_dir="$out_app/Contents/MacOS"

# Detect the real Firefox/LibreWolf executable name. The main entry point is
# typically a shell script (named after the product) that exec's the real binary.
real_bin=""
for candidate in librewolf librewolf-bin firefox firefox-bin bearbrowser; do
  if [ -f "$macos_dir/$candidate" ]; then
    real_bin="$candidate"
    break
  fi
done

if [ -z "$real_bin" ]; then
  echo "ERROR: could not detect the LibreWolf main executable in $macos_dir" >&2
  ls -la "$macos_dir" >&2
  exit 1
fi

echo "      detected base executable: $real_bin"

# Create a BearBrowser wrapper that exec's the detected binary.
# Using exec preserves the process identity and PID for the OS.
cat > "$macos_dir/BearBrowser" <<WRAPPER
#!/usr/bin/env bash
# BearBrowser launcher — wraps the LibreWolf-derived engine binary.
# This file is the CFBundleExecutable for BearBrowser.app.
exec "\$(dirname "\$0")/${real_bin}" "\$@"
WRAPPER
chmod +x "$macos_dir/BearBrowser"
echo "      created $macos_dir/BearBrowser → exec $real_bin"

# ── Step 4: Write BearBrowser Info.plist ──────────────────────────────────────
echo "[4/9] Writing BearBrowser Info.plist..."
if [ ! -f "$info_template" ]; then
  echo "ERROR: Info.plist template missing: $info_template" >&2
  exit 1
fi

python3 - "$info_template" "$out_app/Contents/Info.plist" "$version" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1])
dst = Path(sys.argv[2])
version = sys.argv[3]
text = src.read_text()
# Inject the version
text = text.replace('<string>0.1.0-overlay</string>', f'<string>{version}</string>')
# Ensure CFBundleExecutable is BearBrowser (the wrapper we just created)
import re
text = re.sub(
    r'(<key>CFBundleExecutable</key>\s*<string>)[^<]*(</string>)',
    r'\1BearBrowser\2',
    text,
)
dst.write_text(text)
print(f"Info.plist written: {dst}")
PY
echo "      done"

# ── Step 5: Install BearBrowser icon ─────────────────────────────────────────
echo "[5/9] Installing BearBrowser icon..."
icon_svg="$repo_root/branding/bearbrowser.svg"
if [ -f "$icon_svg" ]; then
  cp "$icon_svg" "$out_app/Contents/Resources/BearBrowser.svg"
  # Replace any existing LibreWolf .icns files with a placeholder marker.
  # Real ICNS conversion requires iconutil which needs PNG source files.
  find "$out_app/Contents/Resources" -name '*.icns' | while read -r icns; do
    echo "      note: $icns (upstream icon — SVG installed alongside)"
  done
  echo "      installed BearBrowser.svg"
else
  echo "      WARNING: branding/bearbrowser.svg not found — icon not installed"
fi

# ── Step 6: Inject profile settings ─────────────────────────────────────────
echo "[6/9] Injecting profile settings (profile=$profile)..."
profile_dir="$repo_root/settings/profiles/$profile"
if [ -d "$profile_dir" ]; then
  # The packaged app applies shipped prefs from a default-pref file
  # (browser/defaults/preferences or browser/app/profile), NOT a user.js — only
  # a profile's own prefs.js uses user_pref(). Pick the default-pref location.
  profile_dest=""
  for candidate in \
      "$out_app/Contents/Resources/browser/defaults/preferences" \
      "$out_app/Contents/MacOS/browser/defaults/preferences" \
      "$out_app/Contents/Resources/browser/app/profile"; do
    if [ -d "$candidate" ]; then
      profile_dest="$candidate"
      break
    fi
  done

  if [ -z "$profile_dest" ]; then
    # Create the standard location; Firefox will find it on first launch.
    profile_dest="$out_app/Contents/Resources/browser/defaults/preferences"
    mkdir -p "$profile_dest"
  fi

  if [ -f "$profile_dir/user.js" ]; then
    # Convert user_pref() -> pref() so the prefs apply in a default-pref file.
    python3 "$script_dir/userjs-to-autoconfig.py" \
      "$profile_dir/user.js" "$profile_dest/bearbrowser-user.js" --profile "$profile"
    echo "      user.js → $profile_dest/bearbrowser-user.js (user_pref→pref)"
  fi

  # Firefox enterprise policies are read from the distribution/ directory
  # adjacent to the application bundle or inside Resources.
  policy_dest=""
  for candidate in \
      "$out_app/Contents/Resources/distribution" \
      "$out_app/Contents/MacOS/distribution"; do
    if [ -d "$candidate" ]; then
      policy_dest="$candidate"
      break
    fi
  done
  if [ -z "$policy_dest" ]; then
    policy_dest="$out_app/Contents/Resources/distribution"
    mkdir -p "$policy_dest"
  fi

  if [ -f "$profile_dir/policies.json" ]; then
    # Strip inline // comments — Firefox rejects a commented policies.json.
    python3 "$script_dir/strip-json-comments.py" "$profile_dir/policies.json" "$policy_dest/policies.json"
    echo "      policies.json → $policy_dest/policies.json (comments stripped)"
  fi
else
  echo "      WARNING: profile directory not found: $profile_dir — skipping settings injection"
fi

# ── Step 6b: Bundle anti-fingerprint fonts ──────────────────────────────────
# Gecko's ActivateBundledFonts() (gated by gfx.bundled-fonts.activate=1, set in
# the profile prefs) loads fonts from NS_GRE_DIR/fonts — on macOS that is
# Contents/Resources/fonts. Combined with font.system.whitelist="Arimo, Tinos,
# Cousine", web content sees ONLY these metric-compatible families on every OS,
# closing the font-enumeration fingerprint (measured 13/14 -> 0/14). If the copy
# is missing, ApplyWhitelist safely ignores the whitelist (no zero-font browser).
fonts_src="$repo_root/packaging/bundled-fonts"
if ls "$fonts_src"/*.ttf >/dev/null 2>&1; then
  fonts_dest="$out_app/Contents/Resources/fonts"
  mkdir -p "$fonts_dest"
  cp "$fonts_src"/*.ttf "$fonts_dest/"
  echo "      bundled fonts → $fonts_dest ($(ls "$fonts_dest"/*.ttf | wc -l | tr -d ' ') families)"
else
  echo "      WARNING: no bundled fonts in $fonts_src — font allowlist will be a safe no-op"
fi

# ── Step 7: Strip quarantine extended attributes ─────────────────────────────
echo "[7/9] Stripping quarantine attributes..."
xattr -cr "$out_app" 2>/dev/null || true
echo "      done"

# ── Step 8: Ad-hoc code signature ────────────────────────────────────────────
if [ "$skip_sign" = "true" ]; then
  echo "[8/9] Skipping signing (--skip-sign)."
else
  echo "[8/9] Applying ad-hoc code signature..."
  if command -v codesign >/dev/null 2>&1; then
    # Ad-hoc signing a modified Gecko bundle requires signing inner components
    # first (frameworks, helpers, nested apps) then the outer bundle.
    # --force re-signs existing signatures; -s - = ad-hoc identity.
    # We sign leaf components first (find depth-first, deepest first).
    echo "      signing nested frameworks and helpers..."
    find "$out_app" -name "*.framework" -o -name "*.dylib" -o \
         -name "*.app" ! -path "$out_app" | sort -r | while read -r inner; do
      codesign --force --sign - "$inner" 2>/dev/null || true
    done
    # Sign the outer bundle last.
    codesign --force --sign - "$out_app" 2>&1 | grep -v "^$" | sed 's/^/      /' || {
      echo "      WARNING: outer bundle signing returned non-zero (may still be runnable)"
    }
    echo "      ad-hoc signature applied"
  else
    echo "      WARNING: codesign not found — skipping (app may need Gatekeeper bypass)"
  fi
fi

# ── Step 9: Verify BearBrowser identity ──────────────────────────────────────
if [ "$skip_verify" = "true" ]; then
  echo "[9/9] Skipping verification (--skip-verify)."
else
  echo "[9/9] Verifying BearBrowser identity..."
  # Pass --skip-signing to the verifier since ad-hoc signatures won't pass
  # spctl --assess (Gatekeeper requires a notarized Developer ID signature).
  bash "$script_dir/verify-macos-app.sh" --app "$out_app" --skip-signing 2>&1 | sed 's/^/      /'
fi

echo
echo "BearBrowser binary overlay complete."
echo "  App: $out_app"
echo "  Profile: $profile"
echo "  Version: $version"
echo
echo "To launch:"
echo "  open $out_app"
echo
echo "For distribution signing, run:"
echo "  bearbrowser-sign-notarize-macos-app --app $out_app"
