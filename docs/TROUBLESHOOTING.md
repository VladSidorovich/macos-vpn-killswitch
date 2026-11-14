# VPN will not reconnect

Is it the kill switch or the VPN? Check in this order.

## 1. Look

- `ksctl status`: tunnel state, which rule set is loaded, known endpoints.
- `/var/log/vpn-killswitch.log`: daemon log (rule set swaps, "endpoints: ...", "pf was disabled; re-enabled",
  "EMERGENCY rules loaded").
- `/var/log/ppp.log`: what the VPN client itself reports.
- `sudo pfctl -a com.apple/000.vpn-killswitch -vsr`: rules with hit counters.
  `sudo pfctl -a com.apple/000.vpn-killswitch -t ks_endpoints -T show` (and `-t ks_dns`): table contents.
- Blocked packets (every block rule logs): `sudo ifconfig pflog0 create` if `pflog0` is missing,
  then `sudo tcpdump -n -e -ttt -i pflog0` while you press Connect.

Nothing blocked during the attempt means the VPN side failed, not the kill switch.

## 2. Failures the kill switch can cause

| Symptom in pflog | Cause | Fix |
|---|---|---|
| UDP 500/4500/1701 or ESP blocked to an address not in `ks_endpoints` | The server IP changed | `sudo ksctl pause 300`, connect (the new endpoint is learned), resume |
| Port 53 blocked to a resolver not in `resolvers` | New network, other DNS server | Add the resolver to `resolvers` in the config, reinstall/restart |
| No DNS at all while down | `endpointDNS: none`, or the emergency set is loaded, and the VPN uses a host name | Use `resolver`, fix the load error (`ksctl status`) |
| Up set stays loaded while disconnected | Missed network event | Wait for the 30 s reconcile; menu shows "Attention" meanwhile |

## 3. Failures that are not the kill switch

pflog shows nothing, and `/var/log/ppp.log` shows one of:

- `rcvd [CHAP Challenge ...]` and then `Authentication failed` / `E=691`, or `No response` after the
  challenge: the login did not complete (late or missed push on the authenticator).
- `IPSec phase 1 server replied` and then `IPSec connection failed` within about a second after a
  drop: the server may still hold the old session. Wait 1 to 2 minutes and retry.
- `No response to 3 echo-requests` / `LCP terminated by peer`, then no answer to retries: server outage.

These also appeared in logs from before the kill switch was installed.

## 4. Re-test without the kill switch

    sudo ksctl pause 300     # or: sudo ksctl off, then ksctl on afterwards

If the VPN still fails, the problem is the VPN. `pause` needs root while the config is `locked`.

## diagnose-reconnect.sh

    sudo ksctl off
    ksctl render --config CONFIG --endpoint IP > up.pf
    ksctl render --config CONFIG --down --endpoint IP > down.pf
    sudo scripts/diagnose-reconnect.sh up.pf down.pf OUT_DIR [SERVICE_NAME]

It cuts the internet for about 40 s per phase. Run `sudo ksctl off` first: a running daemon replaces
the script's rules. Known limit: it starts the VPN with `scutil --nc start`, which cannot complete a
login that needs an authenticator, and its `manual` mode does not work yet (it only lengthens the wait).
