#!/usr/bin/env python3
"""VPN kill switch for macOS (pf based).

Watches for an active VPN tunnel (a utun* interface with an IPv4 address, or a
specific interface via --iface). While none exists, all outbound traffic is
blocked with a pf anchor, except loopback and the hosts given in --allow
(your VPN server, so the client can reconnect). When the VPN is back, the
block is lifted.

Usage:
  ./killswitch.py --status                       # no root needed
  sudo ./killswitch.py --allow 203.0.113.10      # run the watcher
  sudo ./killswitch.py --allow vpn.example.com --allow-lan --interval 1

Stopping (Ctrl+C / SIGTERM) removes the block, so you are never locked out.
If the process is killed with SIGKILL, run:  sudo ./killswitch.py --release
"""
import argparse
import os
import re
import signal
import socket
import subprocess
import sys
import time

ANCHOR = "com.apple/killswitch"  # com.apple/* is evaluated by macOS's default pf.conf
TOKEN_FILE = "/var/run/vpn-killswitch.token"


def sh(cmd, inp=None):
    return subprocess.run(cmd, input=inp, capture_output=True, text=True)


def vpn_up(iface_re):
    names = sh(["ifconfig", "-l"]).stdout.split()
    for n in names:
        if not iface_re.fullmatch(n):
            continue
        out = sh(["ifconfig", n]).stdout
        if "status: inactive" in out:
            continue
        if re.search(r"^\s+inet \d+\.\d+\.\d+\.\d+", out, re.M):
            return n
    return None


def resolve(hosts):
    ips = set()
    for h in hosts:
        try:
            for r in socket.getaddrinfo(h, None):
                ips.add(r[4][0])
        except socket.gaierror:
            print(f"warning: cannot resolve {h}", file=sys.stderr)
    return sorted(ips)


def rules(allow_ips, allow_lan):
    r = ["pass out quick on lo0 all"]
    r += [f"pass out quick to {ip}" for ip in allow_ips]
    r += ["pass out quick proto udp from any port 68 to any port 67"]  # DHCP
    if allow_lan:
        r += ["pass out quick to { 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 }"]
    r += ["block drop out all"]
    return "\n".join(r) + "\n"


def block(ruleset):
    if not os.path.exists(TOKEN_FILE):
        out = sh(["pfctl", "-E"])
        m = re.search(r"Token\s*:\s*(\d+)", out.stdout + out.stderr)
        if m:
            with open(TOKEN_FILE, "w") as f:
                f.write(m.group(1))
    p = sh(["pfctl", "-a", ANCHOR, "-f", "-"], inp=ruleset)
    if p.returncode != 0:
        print("pfctl error:", p.stderr.strip(), file=sys.stderr)


def release():
    sh(["pfctl", "-a", ANCHOR, "-F", "all"])
    if os.path.exists(TOKEN_FILE):
        tok = open(TOKEN_FILE).read().strip()
        sh(["pfctl", "-X", tok])
        os.remove(TOKEN_FILE)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--allow", action="append", default=[], help="VPN server IP/host reachable while blocked (repeatable)")
    ap.add_argument("--allow-lan", action="store_true", help="keep LAN/link-local/multicast open while blocked")
    ap.add_argument("--iface", default=r"utun\d+", help="regex of VPN interface names (default: utun\\d+)")
    ap.add_argument("--interval", type=float, default=1.0, help="poll seconds (default 1)")
    ap.add_argument("--status", action="store_true", help="print VPN state and exit")
    ap.add_argument("--release", action="store_true", help="remove block and exit")
    a = ap.parse_args()
    iface_re = re.compile(a.iface)

    if a.status:
        n = vpn_up(iface_re)
        print(f"VPN up on {n}" if n else "VPN down")
        return
    if os.geteuid() != 0:
        sys.exit("run with sudo")
    if a.release:
        release()
        print("released")
        return

    blocked = False

    def stop(*_):
        release()
        print("\nstopped, block removed")
        sys.exit(0)

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    allow_ips = resolve(a.allow)  # resolve while online
    ruleset = rules(allow_ips, a.allow_lan)
    print(f"watching; allowed while blocked: {allow_ips or 'nothing'}")
    while True:
        up = vpn_up(iface_re)
        if up and blocked:
            release()
            blocked = False
            print(time.strftime("%H:%M:%S"), f"VPN up on {up}: internet unblocked")
        elif not up and not blocked:
            block(ruleset)
            blocked = True
            print(time.strftime("%H:%M:%S"), "VPN down: internet BLOCKED")
        time.sleep(a.interval)


if __name__ == "__main__":
    main()
