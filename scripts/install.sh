#!/bin/bash
# Install killswitchd as a LaunchDaemon. Starts with the kill switch OFF.
#   swift build -c release            (as your user, first)
#   sudo scripts/install.sh CONFIG.json [--with-app]     (--with-app also installs the menu-bar app for you)
# Then: ksctl on --trial 60   and   ksctl confirm
set -eu
LABEL="io.github.vladsidorovich.vpn-killswitch"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBEXEC="/usr/local/libexec/vpn-killswitch"
CONF_DIR="/Library/Application Support/VPNKillSwitch"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
CONFIG_SRC="${1:-}"
WITH_APP="${2:-}"

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -x "$ROOT/.build/release/killswitchd" ] && [ -x "$ROOT/.build/release/ksctl" ] || { echo "build first: swift build -c release" >&2; exit 1; }
[ -f "$CONFIG_SRC" ] || { echo "usage: sudo $0 CONFIG.json" >&2; exit 1; }

# Root code must never live in a place a normal user can write.
safe_dir() {
  local d="$1" owner perms
  owner="$(stat -f %u "$d")"; perms="$(stat -f %Lp "$d")"
  [ "$owner" = 0 ] || { echo "$d is not owned by root" >&2; return 1; }
  [ $(( 0$perms & 0022 )) -eq 0 ] || { echo "$d is group/other writable" >&2; return 1; }
}
mkdir -p /usr/local /usr/local/bin "$LIBEXEC"
for d in /usr/local /usr/local/bin /usr/local/libexec "$LIBEXEC"; do safe_dir "$d"; done

# Validate the config before touching anything
"$ROOT/.build/release/ksctl" render --config "$CONFIG_SRC" >/dev/null

install -m 755 -o root -g wheel "$ROOT/.build/release/killswitchd" "$LIBEXEC/killswitchd"
install -m 755 -o root -g wheel "$ROOT/.build/release/ksctl" /usr/local/bin/ksctl
install -m 755 -o root -g wheel "$ROOT/scripts/panic.sh" "$LIBEXEC/panic.sh"
install -d -m 755 -o root -g wheel "$CONF_DIR"
if [ -e "$CONF_DIR/config.json" ]; then
  echo "keeping existing $CONF_DIR/config.json"
else
  install -m 644 -o root -g wheel "$CONFIG_SRC" "$CONF_DIR/config.json"
fi
install -m 644 -o root -g wheel "$ROOT/packaging/$LABEL.plist" "$PLIST"

launchctl bootout "system/$LABEL" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
if [ "$WITH_APP" = "--with-app" ]; then
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || { echo "--with-app needs sudo from your user account" >&2; exit 1; }
  sudo -u "$SUDO_USER" -H "$ROOT/scripts/install-app.sh"
fi
echo "installed. Mode is OFF. Try: ksctl status ; ksctl on --trial 60 ; ksctl confirm"
echo "Emergency: sudo $LIBEXEC/panic.sh"
