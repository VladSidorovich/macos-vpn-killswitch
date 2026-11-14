# Design: macOS VPN kill switch

Status: M0 to M3 are done: pure core, daemon `killswitchd`, `ksctl` client, install scripts and the
menu-bar app. Live runs with real `pfctl` are recorded under "Verified on the host".

Target VPN: a system L2TP/IPsec service (matched by service UUID; interface
`ppp0` is resolved at runtime). Other services (e.g. "Happ") are ignored.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Delivery | Root LaunchDaemon `killswitchd` + unprivileged clients (`ksctl`, the AppKit menu-bar app) over a unix socket | Only the daemon is root; UI needs no privileges or signing |
| Button vs always-on | One persisted `mode = on/off`; `locked = true` makes `off`/`pause` root-only | One code path covers both |
| Language | Swift (SwiftPM) | System `python3` is the CLT 3.9 shim: no SCDynamicStore/IOKit, can be missing at boot |
| Enforcement | Allowlist anchor loaded permanently while `on`; VPN up/down only changes the tunnel pass rule and `<ks_dns>` contents. Existing connections are not killed when the switch is armed (PO decision) | No leak window on drop; no IPv6/split-route leak while up |
| Anchor | `com.apple/000.vpn-killswitch`, every rule `quick` | Sorts before Apple's `200.*`/`250.*` anchors (verify in VM) |
| Block action | `block return out quick log` | Apps and the VPN client fail fast instead of timing out |
| VPN detection | Match by service UUID; interface from SystemConfiguration. Never "any utun", never wildcard `ppp*` | Removes iCloud/Tailscale/Happ false positives |
| Endpoint traffic | L2TP/IPsec: UDP 500/4500/1701 + ESP to `<ks_endpoints>` | Needed for reconnect |
| Hostname server | IPs resolved only while tunnel is up, cached on disk. While down, DNS (53) allowed to configured resolvers only (`endpointDNS=resolver`) | The OS resolves the name on every connect; leaks DNS names while down, documented |
| Auto-reconnect | Not supported. The VPN login goes through an authenticator, so the daemon never connects the VPN; the user connects by hand | PO: the VPN is always started via the authenticator |
| Management agents | `exemptDestinations`: listed addresses stay reachable while blocked | PO decision: do not block the antivirus/MDM addresses |
| LAN | Blocked by default (`allowLAN=false`) | PO does not use LAN while on VPN |
| Turning off | `locked = true`: `off`/`pause` need root (`sudo ksctl off`). Deliberate no-VPN work = full off, no auto-resume | PO decisions |
| Failure | Fail-closed: crash/SIGTERM keeps rules; only `off`/`panic` removes them. An unreadable `state.json` starts ON when `locked`; if the normal ruleset cannot be built or loaded, a fixed emergency set (loopback, DHCP, VPN establishment, tunnel, block) is loaded and status reports `rules: emergency`. At start while enforcing, the tunnel-down set is loaded from cached endpoints before probing | Prototype failed open on SIGTERM |
| Lockout guards | First arm is a 60 s trial that reverts unless `confirm`ed; refuse to arm with no cached endpoint IPs; `scripts/panic.sh` works without the daemon | |
| Config | JSON, `/Library/Application Support/VPNKillSwitch/config.json` (root:wheel 0644); state in `/var/db/vpn-killswitch/`; binaries in `/usr/local/libexec/vpn-killswitch/` | Never run root code from a user-writable path |
| IPC | Verbs only, never rule text; `getpeereid` check (connection dropped if it fails; default uid is not root); SIGPIPE ignored; up to 4 clients served concurrently with a 2 s read timeout; `status` polls are not logged. `on --force` (no known endpoint) needs `--trial`; trial 10-3600 s; a second `pause` is refused | |
| Events | SCDynamicStore (`State:/Network/Global/IPv4`, `Interface`, `Service/.*/(IPv4|PPP|VPN)`) + a 5 s cheap check (pf enabled, anchor has rules, main-ruleset check) + a 30 s full reconcile. There is no IOKit wake hook: rules persist in the kernel across sleep and the network-change events fire on wake | Repairs drift from MDM/other pf users. A main ruleset that lost `anchor "com.apple/*"`, or has a foreign `quick` pass before it, is only reported (`problems` in status, menu shows degraded); `/etc/pf.conf` is never rewritten, to stay safe next to MDM tools |
| IPv6 | Block all except `lo0` and link-local ND; optional tunnel pass | |
| DHCP | UDP 68 to 67 only to the broadcast address, RFC 1918, link-local and `dhcpServers` (config, for public DHCP servers) | An open port-67 rule let any process reach any host outside the tunnel |
| VMs and containers | Docker Desktop, Podman, Colima/Lima default and OrbStack re-originate traffic as host sockets, so the final block applies (blocked when the VPN is down, tunnelled when up). Bridged adapters (Parallels/UTM/VMware "Bridged") switch frames at layer 2 and bypass pf: **do not use bridged networking**. vmnet shared/NAT guests lose networking (replies leave on `bridge100`, blocked) rather than leak | Assessed from the rule text; not tested with live VMs |

## Menu-bar client (M3)

Plan by an independent planner, adjusted by PO answers. Status: M3.0 (shared client, trial fix) and
M3.1 (pure UI logic, icons, `.app` build, demo mode) and M3.3 (actions, trial panel, notifications)
are done. The app polls `status` every 2 s and drives the daemon. Verified by clicking the menu
through UI scripting against a `--dry-run` daemon with `locked=false`: Turn On, Pause, Resume,
Turn Off, the trial panel and Keep. The password-prompted paths (locked config) compile and are
constant strings, but need a real prompt to try.

| Decision | Choice |
|---|---|
| UI | AppKit `NSStatusItem` + `NSMenu`, SwiftPM executable `KillSwitchBar`, assembled into an ad-hoc signed `.app` by `scripts/build-app.sh` (`LSUIElement`) |
| Icons | Template icons drawn in code from the shield in `assets/menubar-*.svg`: protected (filled), blocked (X cut-out), off (outline), paused (bars + countdown), degraded (`!`), unreachable (`?`); trial adds a countdown title. App icon rendered with CoreGraphics (`scripts/render-icon.swift`, because QuickLook flattens the SVG onto white), `assets/AppIcon.icns` is committed |
| Logic | All decisions are pure functions in `KillSwitchClient` (`UIStateDeriver`, `MenuPlan`, `PrivilegedCommand`, `RecoveryText`) and covered by `ksselftest` |
| Talking to the daemon | `DaemonClient` with 2 s timeouts and typed errors; the app only polls `status`; no protocol change |
| Turn On | Permanent `on`, no trial (PO). `ksctl on --trial` stays for the CLI |
| Pause | One item, 5 minutes (PO); hidden when `maxPauseSeconds` < 300 |
| Turn Off / Pause with `locked` | System password prompt via `osascript ... with administrator privileges` running a constant command (`ksctl off` / `ksctl pause 300`) after checking the binary is root-owned (M3.3). Authorization Services later |
| Connect VPN… | Opens network settings; the login needs an authenticator on the phone, so no app is launched (PO) |
| Notifications | Wanted in the app too (PO), for VPN drop and trial events (needs a one-time permission) |
| Emergency release… | Shown only when the daemon is unreachable or the state is degraded; stops the daemon, then runs the installed `panic.sh` |
| Install | Per-user app in `~/Applications` (PO) with a LaunchAgent (`scripts/install-app.sh`, or `install.sh --with-app`). Verified: starts from `~/Applications`, a crash is relaunched, Quit stays quit (exit 0), `launchctl kickstart` starts it again |

Security note found during planning: before M3.0 a non-root admin could switch a locked, armed kill
switch off with `on --trial 1`. A trial may now start only from off.

## Ruleset shape (L2TP over ppp0)

```
table <ks_endpoints> persist { <cached IPs> }
table <ks_dns> persist { <resolvers, only while tunnel down> }
table <ks_exempt> persist { <exemptDestinations> }
pass quick on lo0 all
pass out quick on ppp0 all keep state (if-bound)          # only while tunnel up
pass out quick inet proto udp from any port 68 to { 255.255.255.255 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 } port 67 keep state (if-bound)
pass out quick inet proto udp to <ks_endpoints> port { 500 4500 1701 } keep state (if-bound)
pass out quick inet proto esp to <ks_endpoints> keep state (if-bound)
pass out quick proto { udp tcp } to <ks_dns> port 53 keep state (if-bound)
pass out quick to <ks_exempt> keep state (if-bound)       # only if configured
pass out quick inet6 proto icmp6 from fe80::/10 icmp6-type { routersol neighbrsol neighbradv } keep state
block return out quick log all
```

Generated by `RulesetBuilder` (`Sources/KillSwitchCore/RulesetBuilder.swift`); view with
`ksctl render --config config/config.example.json`.

## Layout

- `Sources/KillSwitchCore/` — `Config`, `RulesetBuilder`, `VPNMatcher`, `StateMachine` (pure, no I/O).
- `Sources/KillSwitchDaemon/` — `Daemon` (reconcile loop) and `PF` (real and dry-run pfctl wrapper).
- `Sources/killswitchd/` — daemon entry point: IPC server, SCDynamicStore events, 1 s, 5 s and 30 s timers.
- `Sources/ksctl/` — client (`status`, `on`, `confirm`, `off`, `pause`, `resume`) and offline `render`.
- `Sources/KillSwitchClient/`, `Sources/KillSwitchBar/` — shared client logic and the AppKit menu-bar app.
- `packaging/` — LaunchDaemon and login-agent plists. `scripts/` — `install`, `uninstall`, `install-app`, `uninstall-app`, `build-app`, `make-icons`, `panic`, `trial`, `diagnose-reconnect`.
- `docs/RECOVERY.md` — lockout steps. `docs/TROUBLESHOOTING.md` — reconnect problems.
- `Sources/ksselftest/` — plain test runner (`swift run ksselftest`); the Command Line Tools ship no XCTest/Testing modules.
- `prototype/killswitch.py` — first prototype, reference only, not shipped.
- Not written yet: `scripts/leakwatch.sh` (mentioned in the milestones and test plan).

## Milestones (exit criteria, no dates)

- **M0 pure core** — done when the self-tests pass, the rendered rulesets pass `pfctl -nf` (parse only, in a VM), and the matcher ignores Happ/system utun fixtures.
- **M1 daemon + CLI, VM only** — zero leaks (`leakwatch`) across drop/reconnect/network switch/wake/reboot; enforcement restored within one tick after `kill -9`, `pfctl -d`, `pfctl -f /etc/pf.conf`; `panic.sh` works with the daemon stopped; anchor ordering verified; uninstall leaves nothing behind.
- **M2 guarded dogfood on the host** — read-only inventory first, install with mode off, trial arms only, persistent `on` after repeated clean trials; the VPN reconnects while armed; MDM/AV agents stay reachable.
- **M3 menu-bar app** — toggle, pause countdown, trial "Keep" prompt, status icons; no privileges; killing the app does not change enforcement.
- **M4 hardening** — optional `/etc/hosts` pin instead of resolver DNS, admin authorization for locked `off`, release packaging.

## Test plan

Unit/golden tests for the pure core; `pfctl -nf` syntax check in a VM; scoped integration on a `feth` pair; end-to-end in a macOS VM against a lab L2TP server with fault injection; `leakwatch.sh` (read-only tcpdump) during manual sessions. On the managed host only read-only commands until M2, then trial arms.

## Verified on the host (2026-11-13, manual trials with auto-revert)

- Ruleset parses (`pfctl -a ... -nf`); empty `table <x> persist` is accepted. The anchor is evaluated (stock `pf.conf` has `anchor "com.apple/*"`).
- The real VPN endpoint is not what the system resolver returns while connected: the VPN's own DNS answers with an internal address (a private address). The public endpoint is the host route pinned via the physical gateway (`netstat -rn`, entry on `en0`). The daemon must learn the endpoint from that route, or resolve through a non-VPN resolver.
- While the tunnel is up, `block return` makes direct `en0` access fail instantly (`curl --interface en0` fails in about 1 ms).
- Reconnect with the "tunnel down" ruleset (DNS open to the en0 resolvers, IKE/NAT-T/L2TP/ESP to the endpoint): the VPN connected in 24 s with zero blocked VPN-protocol packets.
- Reconnect with the "tunnel up" ruleset (DNS closed): the only blocked packets were DNS queries for the VPN host name, and the VPN could not connect. So the daemon must switch to the "down" set when the service is not connected, and back to the "up" set when it connects.
- The "down" set has no pass rule for the new `ppp0`, so tunnel traffic stays blocked right after connect until the daemon switches sets (60 `ppp0` blocks seen). This confirms the switch is required.
- The VPN login uses an authenticator, so `scutil --nc start` from a script does not connect; connecting is manual. The daemon never reconnects the VPN.
- Sleep/wake and reboot (2026-11-13, checked by the PO and in the daemon log): after wake the daemon swapped down then up set on the network events. After a reboot the daemon started on its own in mode on, loaded the down set at start (tunnel not yet connected), and switched to the up set when the VPN was connected by hand. The menu-bar app started at login.
- Expected side effects while blocked: AirDrop/Handoff/Continuity (`awdl0`, `llw0`, `utun*`) are blocked; apps that send DNS to the en0 resolvers are blocked.

- Live run of the daemon (real `pfctl`, LaunchDaemon, root): trial arm loads the up set; `curl --interface en0` is refused in about 1 ms; an existing SSH session and VPN traffic keep working. On a VPN drop and manual reconnect the daemon swapped down set then up set on network events. Lesson: `dispatchMain()` does not service CFRunLoop sources, so `SCDynamicStore` events need `SCDynamicStoreSetDispatchQueue`; before that fix the swap only happened on the 30 s timer.

## Open items

- Addresses of the management/antivirus agents to put in `exemptDestinations`.
- Local resolver IPs for `endpointDNS=resolver` (the example value is a placeholder).
- Whether IT policy permits a pf-based kill switch on this managed Mac.
- Still unverified: ordering against Apple's `200.*`/`250.*` anchors (nothing in the logs suggests a conflict), the password-prompted paths with a real prompt, behaviour under MDM/antivirus agents over a longer period.

## Escape hatches (in order)

1. `sudo ksctl off`
2. `sudo scripts/panic.sh` (works without the daemon)
3. `sudo pfctl -a com.apple/000.vpn-killswitch -F all`
4. `sudo pfctl -d`
5. `sudo launchctl bootout system/<label>`
6. Recovery OS: delete the LaunchDaemon plist.
