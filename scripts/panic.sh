#!/bin/bash
# Remove the kill switch rules and release pf. Works without any daemon.
#   sudo scripts/panic.sh
ANCHOR="com.apple/000.vpn-killswitch"
TOKEN_FILE="/var/run/vpn-killswitch.token"
if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi
/sbin/pfctl -a "$ANCHOR" -F all 2>/dev/null
if [ -f "$TOKEN_FILE" ]; then
  /sbin/pfctl -X "$(cat "$TOKEN_FILE")" 2>/dev/null
  rm -f "$TOKEN_FILE"
fi
echo "kill switch rules removed"
