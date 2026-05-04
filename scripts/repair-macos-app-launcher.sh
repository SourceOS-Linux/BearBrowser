#!/usr/bin/env bash
set -euo pipefail

target="/Applications/BearBrowser.app"

usage() {
  cat <<'USAGE'
Usage: repair-macos-app-launcher [--target /Applications/BearBrowser.app]

Repairs BearBrowser.app so it opens a usable bootstrap browser engine. It
installs a compiled macOS launcher executable and writes launcher logs to:

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
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

support="$HOME/Library/Application Support/BearBrowser"
profile="$support/profile"
logdir="$HOME/Library/Logs/BearBrowser"
log="$logdir/launcher.log"
landing="$support/BearBrowser-start.html"
mkdir -p "$profile" "$support/policies" "$logdir"
exec >>"$log" 2>&1

echo "---- $(date -u +%Y-%m-%dT%H:%M:%SZ) BearBrowser launcher start ----"
echo "PATH=$PATH"
echo "profile=$profile"

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

cat > "$landing" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BearBrowser</title>
<style>
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#1f1b16;color:#f4efe7;display:grid;place-items:center;min-height:100vh}
main{max-width:760px;padding:48px;border:1px solid #6d4b31;border-radius:28px;background:#2a241d;box-shadow:0 30px 90px rgba(0,0,0,.35)}
h1{font-size:48px;margin:0 0 8px} p{font-size:18px;line-height:1.55;color:#d8cabc}.bear{font-size:64px}.status{margin-top:28px;padding:16px 18px;border-radius:18px;background:#3a3027;color:#f6d28b;font-weight:700} code{color:#f6d28b}
</style>
</head>
<body>
<main>
<div class="bear">🐻</div>
<h1>BearBrowser</h1>
<p>Bootstrap browser surface is running with an isolated BearBrowser profile.</p>
<p>The full BearBrowser runtime remains tracked by the build lane. This interim launcher exists so the app opens visibly from Applications while Lane 13 continues.</p>
<div class="status">Next: <code>bearbrowser-verify-build-lane</code></div>
</main>
</body>
</html>
HTML

landing_url="file://$landing"

for path in \
  "$HOME/Applications/BearBrowser.app/Contents/MacOS/bearbrowser" \
  "/opt/homebrew/bin/bearbrowser-runtime" \
  "/usr/local/bin/bearbrowser-runtime"; do
  if [ -x "$path" ]; then
    echo "launching real BearBrowser runtime: $path"
    "$path" -no-remote -profile "$profile" -new-window "$landing_url" &
    exit 0
  fi
done

activate_app() {
  local app="$1"
  if command -v osascript >/dev/null 2>&1; then
    osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "$app" to activate
APPLESCRIPT
  fi
}

for app in "Firefox" "Firefox Developer Edition"; do
  if /usr/bin/open -Ra "$app" >/dev/null 2>&1; then
    echo "launching bootstrap engine via LaunchServices: $app url=$landing_url"
    /usr/bin/open -na "$app" --args -no-remote -profile "$profile" -new-window "$landing_url"
    activate_app "$app"
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
    echo "launching bootstrap engine directly: $path url=$landing_url"
    "$path" -no-remote -profile "$profile" -new-window "$landing_url" &
    sleep 2
    if pgrep -if "Firefox" >/dev/null 2>&1; then
      echo "direct launch appears active: $path"
      exit 0
    fi
    echo "direct launch attempted but no Firefox process was observed: $path"
  fi
done

echo "ERROR: no local browser engine found"
if command -v osascript >/dev/null 2>&1; then
  osascript <<APPLESCRIPT
set response to display dialog "BearBrowser could not find or start a local browser engine. Install Firefox or complete the BearBrowser build lane. Log: $log" buttons {"OK"} default button "OK" with title "BearBrowser" with icon caution
APPLESCRIPT
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
  if (_NSGetExecutablePath(exe_path, &size) != 0) return 111;
  char resolved[PATH_MAX];
  if (realpath(exe_path, resolved) == NULL) return 112;
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
  for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
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
