#!/bin/bash
set -x
rm -rf AppDir *.AppImage *.zsync
set -e

mkdir -p AppDir/usr/bin AppDir/usr/lib/bearbrowser AppDir/usr/share/applications
mkdir -p AppDir/usr/share/icons/hicolor/scalable/apps

# Copy the BearBrowser binary (graceful if not yet built)
if [ -f dist/linux/BearBrowser ]; then
  install -Dsm755 dist/linux/BearBrowser AppDir/usr/lib/bearbrowser/BearBrowser
else
  echo "BearBrowser binary not present at dist/linux/BearBrowser — AppImage will be incomplete until the GCP build lands"
fi

# Default privacy profile
install -Dm644 profiles/default/user.js AppDir/usr/lib/bearbrowser/defaults/profile/user.js

# Desktop file + icon
install -Dm644 packaging/linux/bearbrowser.desktop AppDir/usr/share/applications/bearbrowser.desktop
install -Dm644 packaging/linux/bearbrowser.desktop AppDir/bearbrowser.desktop
if [ -f branding/bearbrowser.svg ]; then
  install -Dm644 branding/bearbrowser.svg AppDir/usr/share/icons/hicolor/scalable/apps/bearbrowser.svg
  install -Dm644 branding/bearbrowser.svg AppDir/bearbrowser.svg
fi

# AppRun launcher — sets the default profile path
cat > AppDir/AppRun <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export PATH="$HERE/usr/bin:$PATH"
PROFILE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/bearbrowser/profiles/default"
mkdir -p "$PROFILE_DIR"
exec "$HERE/usr/lib/bearbrowser/BearBrowser" --profile "$PROFILE_DIR" "$@"
EOF
chmod 755 AppDir/AppRun

# Fetch appimagetool if needed
[ -x /tmp/appimagetool ] || ( curl -L 'https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage' -o /tmp/appimagetool && chmod +x /tmp/appimagetool )

TAG_NAME=${TAG_NAME:-$(git -c "core.abbrev=8" show -s "--format=%cd-%h" "--date=format:%Y%m%d-%H%M%S")}
OUTPUT=BearBrowser-x86_64.AppImage

ARCH=x86_64 VERSION="$TAG_NAME" /tmp/appimagetool AppDir "$OUTPUT"
