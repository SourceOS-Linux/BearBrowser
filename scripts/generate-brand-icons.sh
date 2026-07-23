#!/usr/bin/env bash
# generate-brand-icons.sh — rasterize branding/bearbrowser.svg into the platform
# icon formats the OSes actually use, committed under branding/icons/:
#
#   bear-{16,32,48,64,128,256,512,1024}.png   (Linux window/desktop icons + sources)
#   BearBrowser.icns                          (macOS app bundle icon)
#   bear.ico                                  (Windows exe/installer icon, multi-size)
#
# Run manually on macOS after changing the SVG (uses qlmanage + iconutil + sips +
# Pillow — all present on a stock dev Mac). CI never runs this; the build lanes
# consume the committed assets (scripts/bearbrowser-patches.py overwrites the
# librewolf-derived browser/branding/bearbrowser rasters with these).
#
# Gotcha encoded: qlmanage renders SVG at high quality but bakes an OPAQUE WHITE
# background — the rounded-rect corners must be re-masked to transparent or the
# icon ships with white corners. The mask radius mirrors the SVG (rx=112 at 512).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg="$repo_root/branding/bearbrowser.svg"
out="$repo_root/branding/icons"
[ -f "$svg" ] || { echo "ERROR: $svg missing" >&2; exit 1; }
command -v qlmanage >/dev/null || { echo "ERROR: qlmanage (macOS) required" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "ERROR: iconutil (macOS) required" >&2; exit 1; }
python3 -c 'import PIL' 2>/dev/null || { echo "ERROR: Pillow required (pip install Pillow)" >&2; exit 1; }

mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "[1/4] Rendering SVG at 1024px (QuickLook)..."
qlmanage -t -s 1024 -o "$tmp" "$svg" >/dev/null
base="$tmp/$(basename "$svg").png"
[ -f "$base" ] || { echo "ERROR: qlmanage produced no PNG" >&2; exit 1; }

echo "[2/4] Masking rounded corners to transparent + generating PNG sizes..."
python3 - "$base" "$out" <<'PY'
import sys
from PIL import Image, ImageDraw

base_path, out = sys.argv[1], sys.argv[2]
im = Image.open(base_path).convert("RGBA")
w = im.width                      # 1024
radius = round(112 / 512 * w)     # SVG: rx=112 on a 512 viewBox

mask = Image.new("L", (w, w), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, w - 1, w - 1], radius=radius, fill=255)
im.putalpha(mask)

for size in (16, 32, 48, 64, 128, 256, 512, 1024):
    scaled = im if size == w else im.resize((size, size), Image.LANCZOS)
    scaled.save(f"{out}/bear-{size}.png")
    print(f"  bear-{size}.png")
PY

echo "[3/4] Building BearBrowser.icns (iconutil)..."
iconset="$tmp/BearBrowser.iconset"
mkdir -p "$iconset"
cp "$out/bear-16.png"   "$iconset/icon_16x16.png"
cp "$out/bear-32.png"   "$iconset/icon_16x16@2x.png"
cp "$out/bear-32.png"   "$iconset/icon_32x32.png"
cp "$out/bear-64.png"   "$iconset/icon_32x32@2x.png"
cp "$out/bear-128.png"  "$iconset/icon_128x128.png"
cp "$out/bear-256.png"  "$iconset/icon_128x128@2x.png"
cp "$out/bear-256.png"  "$iconset/icon_256x256.png"
cp "$out/bear-512.png"  "$iconset/icon_256x256@2x.png"
cp "$out/bear-512.png"  "$iconset/icon_512x512.png"
cp "$out/bear-1024.png" "$iconset/icon_512x512@2x.png"
iconutil -c icns "$iconset" -o "$out/BearBrowser.icns"
echo "  BearBrowser.icns"

echo "[4/4] Building bear.ico (Pillow, multi-size)..."
python3 - "$out" <<'PY'
import sys
from PIL import Image
out = sys.argv[1]
im = Image.open(f"{out}/bear-256.png")
im.save(f"{out}/bear.ico", sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
print("  bear.ico")
PY

echo "Done → $out"
ls -la "$out"
