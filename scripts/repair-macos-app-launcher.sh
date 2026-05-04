#!/usr/bin/env bash
set -euo pipefail

target="/Applications/BearBrowser.app"

usage() {
  cat <<'USAGE'
Usage: repair-macos-app-launcher [--target /Applications/BearBrowser.app]

Repairs BearBrowser.app so it opens a usable bootstrap browser engine instead of
only displaying status. It installs a compiled macOS launcher executable and
writes launcher logs to:

  ~/Library/Logs/BearBrowser/launcher.log
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --target)
      target="${2:?missing target app path}"
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
  echo "ERROR: this command is only supported on macOS" >&2
  exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
  echo "ERROR: clang is required to build the BearBrowser app launcher executable" >&2
  exit 2
fi

if [ ! -d "$target/Contents/MacOS" ]; then
  echo "ERROR: BearBrowser.app is missing Contents/MacOS: $target" >&2
  echo "Run: bearbrowser-install-app-launcher" >&2
  exit 1
fi

resources="$target/Contents/Resources"
macos="$target/Contents/MacOS"
mkdir -p "$resources" "$macos"
launcher_sh="$resources/launcher.sh"
launcher_c="$resources/launcher.c"
exe="$macos/BearBrowser"

cat > "$launcher_sh" <<'EOF'
#!/usr/bin/env bash
set -u
PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

support="$HOME/Library/Application Support/BearBrowser"
profile="$support/profile"
logdir="$HOME/Library/Logs/BearBrowser"
log="$logdir/launcher.log"
mkdir -p "$profile" "$support/policies" "$logdir"
exec >>"$log" 2>&1

echo "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) BearBrowser launcher start ----"
echo "PATH=$PATH"
echo "argv=$*"

cat > "$profile/user.js" <<'PREFS'
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.always_ask_before_handling_new_types", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("signon.rememberSignons", false);
user_pref("media.navigator.enabled", false);
user_pref("geo.enabled", false);
PREFS

cat > "$support/policies/policies.json" <<'POLICIES'
{
  "policies": {
    "DisableTelemetry": true,
    "DisableFirefoxStudies": true,
    "DisablePocket": true,
    "DontCheckDefaultBrowser": true,
    "OfferToSaveLogins": false
  }
}
POLICIES

for path in \
  "$HOME/Applications/BearBrowser.app/Contents/MacOS/bearbrowser" \
  "/opt/homebrew/bin/bearbrowser-runtime" \
  "/usr/local/bin/bearbrowser-runtime"; do
  if [ -x "$path" ]; then
    echo "launching real BearBrowser runtime: $path"
    "$path" -no-remote -profile "$profile" -new-window "about:blank" &
    exit 0
  fi
done

for app in "Firefox" "Firefox Developer Edition"; do
  if /usr/bin/open -Ra "$app" >/dev/null 2>&1; then
    echo "launching bootstrap engine via LaunchServices: $app"
    /usr/bin/open -na "$app" --args -no-remote -profile "$profile" -new-window "about:blank"
    sleep 2
    if pgrep -if "Firefox" >/dev/null 2>&1; then
      echo "bootstrap launch appears active: $app"
      exit 0
    fi
    echo "LaunchServices attempted $app but no Firefox process was observed"
  fi
done

for path in \
  "/Applications/Firefox.app/Contents/MacOS/firefox" \
  "/Applications/Firefox Developer Edition.app/Contents/MacOS/firefox" \
  "/opt/homebrew/bin/firefox" \
  "/usr/local/bin/firefox"; do
  if [ -x "$path" ]; then
    echo "launching bootstrap engine directly: $path"
    "$path" -no-remote -profile "$profile" -new-window "about:blank" &
    sleep 2
    if pgrep -if "Firefox" >/dev/null 2>&1; then
      echo "direct launch appears active: $path"
      exit 0
    fi
    echo "direct launch attempted but no Firefox process was observed: $path"
  fi
done

msg="BearBrowser launcher could not find or start a local browser engine.\n\nInstall Firefox for the temporary bootstrap runtime, or complete the BearBrowser build lane.\n\nCommands:\n  brew install --cask firefox\n  bearbrowser-verify-build-lane\n\nLog:\n  $log"

echo "ERROR: $msg"
if command -v osascript >/dev/null 2>&1; then
  osascript <<APPLESCRIPT
set response to display dialog "$msg" buttons {"OK"} default button "OK" with title "BearBrowser" with icon caution
APPLESCRIPT
else
  echo "$msg"
fi
exit 64
EOF
chmod +x "$launcher_sh"

cat > "$launcher_c" <<'EOF'
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char exe_path[PATH_MAX];
  uint32_t size = sizeof(exe_path);
  if (_NSGetExecutablePath(exe_path, &size) != 0) {
    return 111;
  }

  char resolved[PATH_MAX];
  if (realpath(exe_path, resolved) == NULL) {
    return 112;
  }

  char dirbuf[PATH_MAX];
  strncpy(dirbuf, resolved, sizeof(dirbuf));
  dirbuf[sizeof(dirbuf) - 1] = '\0';
  char *macos_dir = dirname(dirbuf);

  char script[PATH_MAX];
  snprintf(script, sizeof(script), "%s/../Resources/launcher.sh", macos_dir);

  char **args = calloc((size_t)argc + 3, sizeof(char *));
  if (!args) return 113;
  args[0] = "/bin/bash";
  args[1] = script;
  for (int i = 1; i < argc; i++) {
    args[i + 1] = argv[i];
  }
  args[argc + 1] = NULL;
  execv("/bin/bash", args);
  perror("execv");
  return 114;
}
EOF

clang "$launcher_c" -o "$exe"
chmod +x "$exe"
xattr -dr com.apple.quarantine "$target" 2>/dev/null || true

lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$lsregister" ]; then
  "$lsregister" -f "$target" || true
fi

/usr/bin/touch "$target"

echo "Repaired BearBrowser app launcher with compiled executable: $target"
echo "Open: open '$target'"
echo "Log: ~/Library/Logs/BearBrowser/launcher.log"
