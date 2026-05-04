#!/usr/bin/env bash
set -euo pipefail

target="/Applications/BearBrowser.app"
version="${BEARBROWSER_VERSION:-0.1.0-overlay}"

usage() {
  cat <<'USAGE'
Usage: install-macos-app-launcher [--target /Applications/BearBrowser.app] [--version VERSION]

Installs a local BearBrowser.app launcher into /Applications.

This is a launcher for the installed BearBrowser tooling and product surface.
The full browser binary/app bundle is tracked separately by Lane 13 and Lane 15.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      target="${2:?missing target app path}"
      shift 2
      ;;
    --version)
      version="${2:?missing version}"
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

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: macOS app launcher install is only supported on Darwin/macOS" >&2
  exit 1
fi

if ! command -v iconutil >/dev/null 2>&1; then
  echo "ERROR: iconutil is required to build the BearBrowser app icon" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to build the BearBrowser app icon" >&2
  exit 2
fi

workdir="$(mktemp -d)"
app="$workdir/BearBrowser.app"
contents="$app/Contents"
resources="$contents/Resources"
macos="$contents/MacOS"
iconset="$workdir/BearBrowser.iconset"

mkdir -p "$resources" "$macos" "$iconset"

cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>BearBrowser</string>
  <key>CFBundleDisplayName</key>
  <string>BearBrowser</string>
  <key>CFBundleIdentifier</key>
  <string>dev.sourceos.BearBrowser</string>
  <key>CFBundleExecutable</key>
  <string>BearBrowser</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>BearBrowser</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cat > "$macos/BearBrowser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

msg="BearBrowser tooling is installed.\n\nThe full GUI browser runtime is tracked by the build lane.\n\nUse Terminal commands for now:\n  bearbrowser-doctor\n  bearbrowser-verify-build-lane"

if command -v osascript >/dev/null 2>&1; then
  choice="$(osascript <<APPLESCRIPT
set response to display dialog "$msg" buttons {"Open Terminal", "OK"} default button "OK" with title "BearBrowser" with icon note
button returned of response
APPLESCRIPT
)"
  if [ "$choice" = "Open Terminal" ]; then
    osascript <<'APPLESCRIPT'
tell application "Terminal"
  activate
  do script "bearbrowser-doctor; echo; bearbrowser-verify-build-lane; echo; echo 'BearBrowser launcher is installed at /Applications/BearBrowser.app';"
end tell
APPLESCRIPT
  fi
else
  echo "$msg"
fi
EOF
chmod +x "$macos/BearBrowser"

python3 - "$iconset" <<'PY'
from pathlib import Path
import struct, zlib, sys, math

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

def png(path, size):
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            nx = (x + 0.5) / size
            ny = (y + 0.5) / size
            # rounded brown background
            bg = (80, 48, 25, 255)
            face = (184, 119, 58, 255)
            ear = (92, 53, 29, 255)
            dark = (31, 20, 14, 255)
            cream = (237, 190, 117, 255)
            r = min(nx, ny, 1-nx, 1-ny)
            col = bg if r > 0.06 else (0,0,0,0)
            def circle(cx, cy, rr):
                return (nx-cx)**2 + (ny-cy)**2 <= rr**2
            if circle(.31,.30,.14) or circle(.69,.30,.14): col = ear
            if circle(.31,.30,.075) or circle(.69,.30,.075): col = cream
            if ((nx-.5)/.34)**2 + ((ny-.57)/.36)**2 <= 1: col = face
            if circle(.38,.55,.045) or circle(.62,.55,.045): col = dark
            if ((nx-.5)/.095)**2 + ((ny-.66)/.06)**2 <= 1: col = dark
            if abs(ny-.81) < .018 and .26 < nx < .74: col = cream
            row += bytes(col)
        rows.append(bytes(row))
    raw = b''.join(rows)
    def chunk(tag, data):
        return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag+data) & 0xffffffff)
    data = b'\x89PNG\r\n\x1a\n'
    data += chunk(b'IHDR', struct.pack('!IIBBBBB', size, size, 8, 6, 0, 0, 0))
    data += chunk(b'IDAT', zlib.compress(raw, 9))
    data += chunk(b'IEND', b'')
    path.write_bytes(data)

sizes = [(16, 'icon_16x16.png'), (32, 'icon_16x16@2x.png'), (32, 'icon_32x32.png'), (64, 'icon_32x32@2x.png'), (128, 'icon_128x128.png'), (256, 'icon_128x128@2x.png'), (256, 'icon_256x256.png'), (512, 'icon_256x256@2x.png'), (512, 'icon_512x512.png'), (1024, 'icon_512x512@2x.png')]
for size, name in sizes:
    png(out / name, size)
PY

iconutil -c icns "$iconset" -o "$resources/BearBrowser.icns"

rm -rf "$target"
mkdir -p "$(dirname "$target")"
cp -R "$app" "$target"
chmod -R u+rwX,go+rX "$target"
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

rm -rf "$workdir"

echo "Installed BearBrowser app launcher: $target"
echo "Open it from Finder, Spotlight, or: open -a BearBrowser"
