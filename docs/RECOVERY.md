# If you are locked out

The kill switch blocks traffic when the VPN is down. These steps remove it, in order.
The menu-bar item "If I am locked out…" shows the same list.

1. Turn it off normally (needs your administrator password, the config is locked):

       sudo ksctl off

2. If the daemon is stuck and `ksctl` does not answer, stop the daemon **first**, then remove the rules.
   The order matters: while the daemon runs and enforces, a 5 s check turns pf back on and reloads
   emptied rules, and launchd restarts a killed daemon (`KeepAlive`), so `kill` does not help:

       sudo launchctl bootout system/io.github.vladsidorovich.vpn-killswitch
       sudo /usr/local/libexec/vpn-killswitch/panic.sh

3. Last resort, switch pf off completely (only after step 2's `bootout`; with the daemon running
   it is undone within about 5 s):

       sudo pfctl -d

The menu-bar item "Emergency release…" does step 2 for you. It appears only when the daemon is
unreachable or degraded.

A reboot alone does not help while the daemon is installed and the mode is on: it starts
again and reloads the rules. Stop the daemon first. In Recovery OS you can delete
`/Library/LaunchDaemons/io.github.vladsidorovich.vpn-killswitch.plist`.

After `panic.sh` or `bootout`, run `sudo scripts/install.sh config/config.local.json` to bring
the daemon back (it starts in the mode that was saved).
