#!/bin/bash
# Test whether the VPN can reconnect while the kill switch rules are loaded.
# Runs two phases (rules-up.pf, then rules-down.pf). Each phase: disconnect VPN,
# load rules with auto-revert, try to reconnect, record result and blocked packets.
# Everything is restored at the end. Report goes to OUT_DIR/report.txt.
#
#   sudo scripts/diagnose-reconnect.sh RULES_UP RULES_DOWN OUT_DIR [SERVICE_NAME] ["up down"|down|up] [manual]
#
# Internet is blocked for up to ~45 s in each phase. Always recoverable:
# sudo scripts/panic.sh, or reboot.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
UP="${1:-}"; DOWN="${2:-}"; OUT="${3:-}"; SVC="${4:-My VPN}"
WAIT=40            # seconds to wait for the VPN to connect in each phase
[ "${6:-}" = manual ] && WAIT=90
GUARD=$((WAIT + 40))

if [ "$(id -u)" -ne 0 ]; then echo "run with sudo" >&2; exit 1; fi
if [ -z "${SUDO_USER:-}" ] || [ "$SUDO_USER" = root ]; then echo "run via sudo from your user account" >&2; exit 1; fi
if [ ! -f "$UP" ] || [ ! -f "$DOWN" ] || [ -z "$OUT" ]; then
  echo "usage: sudo $0 RULES_UP RULES_DOWN OUT_DIR [SERVICE_NAME]" >&2; exit 1
fi
mkdir -p "$OUT"; REPORT="$OUT/report.txt"; : > "$REPORT"
log() { echo "$*" | tee -a "$REPORT"; }
asuser() { sudo -u "$SUDO_USER" "$@"; }
status() { asuser /usr/sbin/scutil --nc status "$SVC" 2>/dev/null | head -1; }

wait_for() {   # wait_for STATE SECONDS -> prints seconds taken, returns 0 on success
  local want="$1" max="$2" i=0
  while [ "$i" -lt "$max" ]; do
    [ "$(status)" = "$want" ] && { echo "$i"; return 0; }
    sleep 1; i=$((i + 1))
  done
  return 1
}

TCPDUMP_PID=""
cleanup() {
  [ -n "$TCPDUMP_PID" ] && kill "$TCPDUMP_PID" 2>/dev/null
  "$HERE/panic.sh" >/dev/null 2>&1
  pkill -f "sleep ${GUARD}; " 2>/dev/null
  if [ "$(status)" != "Connected" ]; then asuser /usr/sbin/scutil --nc start "$SVC" >/dev/null 2>&1; fi
}
trap cleanup EXIT INT TERM

log "== diagnose-reconnect $(date '+%F %T')  service=$SVC"
log "start state: $(status)"

# pflog0 shows packets blocked by rules that carry `log`
/sbin/ifconfig pflog0 >/dev/null 2>&1 || /sbin/ifconfig pflog0 create

phase() {   # phase NAME RULES_FILE
  local name="$1" rules="$2" t
  log ""; log "---- phase: $name ($rules)"
  # make sure we start connected, then disconnect cleanly
  if [ "$(status)" != "Connected" ]; then
    asuser /usr/sbin/scutil --nc start "$SVC" >/dev/null 2>&1
    wait_for Connected 40 >/dev/null || { log "could not start from a clean state, skipping"; return; }
  fi
  asuser /usr/sbin/scutil --nc stop "$SVC" >/dev/null 2>&1
  wait_for Disconnected 15 >/dev/null || log "warning: VPN did not report Disconnected"

  /usr/sbin/tcpdump -nel -tttt -i pflog0 > "$OUT/blocked-$name.txt" 2>&1 &
  TCPDUMP_PID=$!
  sleep 1

  "$HERE/trial.sh" "$rules" "$GUARD" >> "$OUT/trial-$name.txt" 2>&1 || { log "trial.sh failed, see trial-$name.txt"; kill "$TCPDUMP_PID" 2>/dev/null; TCPDUMP_PID=""; return; }

  if [ "${6:-}" = manual ]; then
    log ">>> NOW: click Connect on '$SVC' in the menu bar. Waiting up to ${WAIT}s."
  else
    asuser /usr/sbin/scutil --nc start "$SVC" >/dev/null 2>&1
  fi
  if t=$(wait_for Connected "$WAIT"); then
    log "RESULT: VPN CONNECTED after ${t}s with these rules"
  else
    log "RESULT: VPN did NOT connect within ${WAIT}s (last status: $(status))"
  fi

  "$HERE/panic.sh" >/dev/null 2>&1
  pkill -f "sleep ${GUARD}; " 2>/dev/null   # cancel this phase's pending auto-revert so it cannot hit the next phase
  sleep 1
  kill "$TCPDUMP_PID" 2>/dev/null; TCPDUMP_PID=""
  local n; n=$(grep -c . "$OUT/blocked-$name.txt")
  log "blocked-packet log lines: $n (file: blocked-$name.txt)"
  # restore the VPN before the next phase
  if [ "$(status)" != "Connected" ]; then
    asuser /usr/sbin/scutil --nc start "$SVC" >/dev/null 2>&1
    wait_for Connected 40 >/dev/null || log "warning: VPN not reconnected after rules were removed"
  fi
}

PHASES="${5:-up down}"
for p in $PHASES; do
  case "$p" in
    up) phase up "$UP" ;;
    down) phase down "$DOWN" ;;
    *) log "unknown phase: $p" ;;
  esac
done

log ""; log "end state: $(status)"
chmod -R a+rX "$OUT"
echo; echo "Report: $REPORT"
