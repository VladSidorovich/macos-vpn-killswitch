# macos-vpn-killswitch

A VPN kill switch for macOS built on the `pf` firewall. While it is on, all traffic that does not go
through your VPN is blocked, and the block applies the moment the tunnel drops (no polling gap).
It supports system L2TP/IPsec VPN services (listed by `scutil --nc list`, matched by UUID); other VPN
types need code changes. The daemon never connects the VPN: you connect it yourself, which also
matches logins that use an authenticator.

- **Daemon** `killswitchd` (root LaunchDaemon): keeps one `pf` anchor in sync with the VPN state.
- **CLI** `ksctl`: `status`, `on`, `off`, `pause`, `confirm`, `resume`, and `render` (prints the rules offline).
- **Menu-bar app** `KillSwitchBar`: status icon, Turn On / Turn Off / Pause, trial banner, notifications.

Design, decisions and what was verified: [docs/DESIGN.md](docs/DESIGN.md).
If you lose connectivity: [docs/RECOVERY.md](docs/RECOVERY.md).
VPN will not reconnect: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Requirements

macOS 13 or later and the Command Line Tools (Swift 6). No Xcode needed.

## Install

1. Copy `config/config.example.json` to `config/config.local.json` and set your VPN service
   (`scutil --nc list` shows the UUID and name), your resolvers and any addresses that must stay reachable.
   `config.local.json` is git-ignored.
2. `swift build -c release`
3. `sudo scripts/install.sh config/config.local.json --with-app`
   Installs the daemon (starts with the kill switch **off**) and, for your user, the menu-bar app and its login agent.
4. Connect the VPN once. `ksctl on` refuses ("no VPN endpoint address known yet") until an endpoint is
   learned, which happens while the tunnel is up. Then `ksctl status`, and turn it on from the menu or
   with `ksctl on`. To try it safely first: `ksctl on --trial 60`, then `ksctl confirm`.

Remove everything: `sudo scripts/uninstall.sh --purge`. App only: `scripts/uninstall-app.sh`.

## Tests

`swift run ksselftest` runs the self-tests (a plain executable, because the Command Line Tools ship no XCTest).

## Notes

- With `locked: true` (default), turning it off or pausing needs an administrator password.
- The VPN login is not automated; connect the VPN yourself. While it is down, traffic is blocked
  except to the VPN server, DNS (to the configured resolvers) and any `exemptDestinations`.
- A reboot alone does not remove the rules while the daemon is installed; see the recovery doc.
- `install.sh` installs the binaries from `.build/release`: run `swift build -c release` again after
  every code change, or it installs the old build. It keeps an existing config; the daemon restarts
  and the rules stay loaded. If it prints `Bootstrap failed: 5`, run it again. The line "Mode is OFF"
  it prints is generic; check `ksctl status` for the real mode.
- `dhcpServers` (optional config list): extra DHCP server addresses to allow. DHCP is otherwise
  allowed only to broadcast, private ranges and link-local.

## Fail-closed behaviour

- Stopping or crashing the daemon keeps the rules. Only `off` or `panic.sh` removes them.
- At start, while enforcing, the "VPN down" rules are loaded from cached endpoints before anything is
  probed. If `state.json` is unreadable and the config is `locked`, the daemon starts **on**.
- If the normal ruleset cannot be loaded, a fixed emergency set (loopback, DHCP, VPN establishment,
  the tunnel, block) is loaded and the menu shows "attention".
- A 5 s check re-enables pf if something turned it off, and re-loads an emptied anchor. If another
  tool removes the `com.apple/*` anchor from the main ruleset, or puts a `quick` pass rule ahead of
  it, the menu shows "Attention" (`/etc/pf.conf` is never rewritten). This check runs only while
  enforcing (on and not paused), and it also undoes `sudo pfctl -d` and `panic.sh` while the daemon
  runs: stop the daemon first, see [docs/RECOVERY.md](docs/RECOVERY.md).
- Existing connections are not dropped when the kill switch is armed.

## Docker and virtual machines

- Docker Desktop, Podman, Colima/Lima (default networking) and OrbStack do **not** bypass it: their
  traffic leaves as ordinary host traffic, so it is blocked while the VPN is down and tunnelled when up.
- **Do not use bridged networking** in Parallels, UTM or VMware. Bridged guests are switched at
  layer 2 and bypass `pf` entirely, with the VPN up or down. NAT ("shared") guests lose networking
  while the kill switch is on instead of leaking.
- This is assessed from the rules, not tested with live VMs.

## Checks after install

- `ksctl status` shows `rules: up set, pf enabled` while the VPN is connected.
- `sudo pfctl -d`, then within about 10 s `ksctl status` shows `pf enabled` again.
- `sudo lsof -p $(pgrep killswitchd) | wc -l` stays around 30-40 and does not grow.
- Reconnect: disconnect the VPN; `ksctl status` shows `tunnel: disconnected` and the down set. Wait
  about a minute, connect by hand; it returns to `tunnel: connected` and `rules: up set, pf enabled`.
- Emergency exit: `sudo /usr/local/libexec/vpn-killswitch/panic.sh`.
