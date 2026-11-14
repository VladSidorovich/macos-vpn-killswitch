#!/bin/bash
# Load a rendered ruleset into the kill switch anchor, with an automatic revert.
# The revert is started BEFORE the rules are loaded and runs detached, so it
# fires even if the terminal closes or the network is blocked.
#   sudo scripts/trial.sh RULES_FILE [SECONDS]      (default 60)
# Always recoverable: sudo scripts/panic.sh, or reboot (nothing is persisted).
set -u
ANCHOR="com.apple/000.vpn-killswitch"
TOKEN_FILE="/var/run/vpn-killswitch.token"
PFCTL=/sbin/pfctl
RULES="${1:-}"; SECS="${2:-60}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi
if [ ! -f "$RULES" ]; then echo "usage: sudo $0 RULES_FILE [SECONDS]" >&2; exit 1; fi
case "$SECS" in (''|*[!0-9]*) echo "SECONDS must be a number" >&2; exit 1;; esac

# 1. parse only; nothing is loaded
if ! out=$($PFCTL -a "$ANCHOR" -nf "$RULES" 2>&1); then
  echo "rules do not parse, nothing changed:" >&2; echo "$out" >&2; exit 1
fi
echo "rules parse OK"

# 2. arm the revert first
nohup bash -c "sleep $SECS; '$HERE/panic.sh'" >/dev/null 2>&1 &
echo "auto-revert scheduled in ${SECS}s (pid $!)"

# 3. enable pf (reference counted) and load the anchor
tok=$($PFCTL -E 2>&1 | sed -n 's/.*Token : *//p')
[ -n "$tok" ] && echo "$tok" > "$TOKEN_FILE"
if ! $PFCTL -a "$ANCHOR" -f "$RULES"; then
  echo "load failed, reverting now" >&2; "$HERE/panic.sh"; exit 1
fi
echo "LOADED. Rules will be removed automatically in ${SECS}s."
echo "Remove now: sudo $HERE/panic.sh"
