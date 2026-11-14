#!/bin/bash
# Remove the menu-bar app and its login agent for the current user.
#   scripts/uninstall-app.sh
LABEL="io.github.vladsidorovich.vpn-killswitch.bar"
[ "$(id -u)" -ne 0 ] || { echo "run as your normal user, not root" >&2; exit 1; }
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -x KillSwitchBar 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/KillSwitchBar.app"
echo "menu-bar app removed"
