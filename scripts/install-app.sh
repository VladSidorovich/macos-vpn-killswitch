#!/bin/bash
# Install the menu-bar app for the current user: ~/Applications + a LaunchAgent that starts it at login.
# Run as your normal user (not sudo). The daemon is installed separately, system-wide, by install.sh.
#   scripts/install-app.sh
set -eu
LABEL="io.github.vladsidorovich.vpn-killswitch.bar"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/KillSwitchBar.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }

"$ROOT/scripts/build-app.sh"
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"

# stop any running copy (an old install or one started by hand) before replacing the files
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x KillSwitchBar 2>/dev/null || true

rm -rf "$DEST"
ditto "$ROOT/.build/KillSwitchBar.app" "$DEST"
codesign --verify --strict "$DEST"

sed "s#__HOME__#$HOME#g" "$ROOT/packaging/$LABEL.plist" > "$AGENT"
plutil -lint "$AGENT" >/dev/null
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "installed $DEST and the login agent; the app is running now"
