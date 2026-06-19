#!/usr/bin/env bash
# Install BearBrowserPolicyQueue as a macOS LaunchAgent (runs at login, stays alive).
#
# Usage:
#   bash scripts/install-policy-queue-agent.sh          # build + install + load
#   bash scripts/install-policy-queue-agent.sh --unload  # stop + unload + remove plist
#
# Requires: swiftc (Xcode Command Line Tools)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY_DEST="/usr/local/bin/BearBrowserPolicyQueue"
PLIST_SRC="$REPO_ROOT/native/macos/ai.socioprophet.bearbrowser.policy-queue.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/ai.socioprophet.bearbrowser.policy-queue.plist"
LABEL="ai.socioprophet.bearbrowser.policy-queue"

unload() {
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "==> Unloaded $LABEL" || true
    rm -f "$PLIST_DEST" && echo "==> Removed $PLIST_DEST" || true
    echo "Done. Binary at $BINARY_DEST is untouched — remove manually if desired."
}

if [[ "${1:-}" == "--unload" ]]; then
    unload
    exit 0
fi

# Build
echo "==> Building BearBrowserPolicyQueue..."
bash "$REPO_ROOT/scripts/build-hold-queue-app.sh" --install

# Install plist
mkdir -p "$HOME/Library/LaunchAgents"
# Rewrite ProgramArguments path in case binary is elsewhere
sed "s|/usr/local/bin/BearBrowserPolicyQueue|$BINARY_DEST|g" \
    "$PLIST_SRC" > "$PLIST_DEST"
echo "==> Installed plist: $PLIST_DEST"

# Unload any prior instance, then load fresh
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
echo "==> Loaded LaunchAgent: $LABEL"

echo ""
echo "Policy queue is now running and will restart at each login."
echo "To check status: launchctl print gui/$(id -u)/$LABEL"
echo "To unload:        bash scripts/install-policy-queue-agent.sh --unload"
