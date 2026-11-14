#!/bin/bash
# Stop the daemon, remove its rules and files. Keeps the config unless --purge.
#   sudo scripts/uninstall.sh [--purge]
LABEL="io.github.vladsidorovich.vpn-killswitch"
HERE="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
launchctl bootout "system/$LABEL" 2>/dev/null
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  sudo -u "$SUDO_USER" -H "$HERE/uninstall-app.sh" || true
fi
"$HERE/panic.sh"
rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/bin/ksctl /var/run/vpn-killswitch.sock /var/run/vpn-killswitch.token
rm -rf /usr/local/libexec/vpn-killswitch /var/db/vpn-killswitch
if [ "${1:-}" = "--purge" ]; then rm -rf "/Library/Application Support/VPNKillSwitch" /var/log/vpn-killswitch.log; fi
echo "uninstalled"
