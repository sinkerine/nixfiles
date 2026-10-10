#!/usr/bin/env python3
"""Persist and restore Asako's local TUN routing choice."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import json
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


STATE_DIR = Path(os.environ.get("ASAKO_PROXY_STATE_DIR", "/var/lib/asako-proxy"))
STATE_FILE = STATE_DIR / "state"
SYSTEMCTL = os.environ.get("ASAKO_SYSTEMCTL", "systemctl")
IP = os.environ.get("ASAKO_IP", "ip")
IPTABLES = os.environ.get("ASAKO_IPTABLES", "iptables")
IP6TABLES = os.environ.get("ASAKO_IP6TABLES", "ip6tables")
CLASH_API = os.environ.get("ASAKO_CLASH_API", "http://127.0.0.1:19090")
HK_TUN = "sing-box-hk-tun.service"
HK_INTERFACE = "singtun-hk0"
HK_TABLE = "109"
GUARD_TABLE = "110"
TAILNET_CIDRS = ("100.64.0.0/10", "fd7a:115c:a1e0::/48")
CLASH_ATTEMPTS = int(os.environ.get("ASAKO_CLASH_ATTEMPTS", "30"))
CLASH_RETRY_DELAY = float(os.environ.get("ASAKO_CLASH_RETRY_DELAY", "1"))
HK_INTERFACE_ATTEMPTS = int(os.environ.get("ASAKO_HK_INTERFACE_ATTEMPTS", "20"))
HK_INTERFACE_RETRY_DELAY = float(os.environ.get("ASAKO_HK_INTERFACE_RETRY_DELAY", "0.5"))


def save(choice):
    STATE_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    temporary = STATE_DIR / "state.tmp"
    temporary.write_text(choice + "\n", encoding="ascii")
    temporary.chmod(0o644)
    temporary.replace(STATE_FILE)


def run(command, *args):
    subprocess.run([command, *args], check=True)


def guard_tailnet(enabled):
    # Install both blackholes before exposing their rules to any traffic.
    if enabled:
        for cidr in TAILNET_CIDRS:
            family = "-6" if ":" in cidr else "-4"
            run(IP, family, "route", "replace", "blackhole", cidr, "table", GUARD_TABLE)
        for cidr in TAILNET_CIDRS:
            family = "-6" if ":" in cidr else "-4"
            remove_tailnet_rules(family, 1001, cidr, GUARD_TABLE)
            run(IP, family, "rule", "add", "priority", "1001", "iif", "lo", "to", cidr, "lookup", GUARD_TABLE)
        return

    for cidr in TAILNET_CIDRS:
        family = "-6" if ":" in cidr else "-4"
        remove_tailnet_rules(family, 1001, cidr, GUARD_TABLE)
        remove_route(family, cidr, GUARD_TABLE, blackhole=True)


def remove_rule(family, priority, cidr, table):
    subprocess.run([IP, family, "rule", "del", "priority", str(priority), "to", cidr, "lookup", table])


def remove_tailnet_rules(family, priority, cidr, table):
    # Remove the former unscoped rule during upgrade, then any scoped copy.
    remove_rule(family, priority, cidr, table)
    subprocess.run([
        IP, family, "rule", "del", "priority", str(priority),
        "iif", "lo", "to", cidr, "lookup", table,
    ])


def remove_route(family, cidr, table, blackhole=False):
    args = [IP, family, "route", "del"]
    if blackhole:
        args.append("blackhole")
    args.extend([cidr, "table", table])
    subprocess.run(args)


def hk_route(enabled):
    # Table 109 takes precedence over the guard only while HK TUN is selected.
    if enabled:
        for cidr in TAILNET_CIDRS:
            family = "-6" if ":" in cidr else "-4"
            run(IP, family, "route", "replace", cidr, "dev", HK_INTERFACE, "table", HK_TABLE)
            remove_tailnet_rules(family, 1000, cidr, HK_TABLE)
            run(IP, family, "rule", "add", "priority", "1000", "iif", "lo", "to", cidr, "lookup", HK_TABLE)
        return

    for cidr in TAILNET_CIDRS:
        family = "-6" if ":" in cidr else "-4"
        remove_tailnet_rules(family, 1000, cidr, HK_TABLE)
        remove_route(family, cidr, HK_TABLE)


def wait_for_hk_interface():
    for _ in range(HK_INTERFACE_ATTEMPTS):
        interface = subprocess.run(
            [IP, "link", "show", "dev", HK_INTERFACE],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if interface.returncode == 0:
            return
        time.sleep(HK_INTERFACE_RETRY_DELAY)
    raise RuntimeError(f"HK TUN interface {HK_INTERFACE} did not become ready")


def tailnet_return_rule(enabled):
    """Allow established tailnet replies arriving through the HK TUN."""
    for family, executable, cidr in (
        ("-4", IPTABLES, "100.64.0.0/10"),
        ("-6", IP6TABLES, "fd7a:115c:a1e0::/48"),
    ):
        rules = subprocess.run(
            [executable, "-S", "ts-input"], capture_output=True, text=True,
        )
        if rules.returncode:
            if enabled:
                raise RuntimeError(f"{executable} ts-input chain is unavailable")
            continue

        scoped = []
        for line in rules.stdout.splitlines():
            if not line.startswith("-A ts-input "):
                continue
            args = shlex.split(line)[2:]
            try:
                states = set(args[args.index("--ctstate") + 1].split(","))
            except (ValueError, IndexError):
                states = set()
            if (
                args[args.index("-i") + 1] == HK_INTERFACE
                if "-i" in args else False
            ) and f"-s {cidr}" in line and states == {"ESTABLISHED", "RELATED"} and "-j ACCEPT" in line:
                scoped.append(args)
        if enabled:
            if scoped:
                continue
            # Tailscale's anti-spoof DROP must remain in place for every other
            # interface. Insert this exception immediately before that rule.
            lines = rules.stdout.splitlines()
            drop_index = next((
                index for index, line in enumerate(lines)
                if line.startswith("-A ts-input ")
                and f"-s {cidr}" in line and "-j DROP" in line
            ), None)
            if drop_index is None:
                # Tailscale installs the CGNAT anti-spoof drop only for IPv4.
                # IPv6 replies need no exception when that drop is absent.
                if family == "-6":
                    continue
                raise RuntimeError(f"{executable} tailnet anti-spoof rule is unavailable")
            drop_position = sum(line.startswith("-A ts-input ") for line in lines[:drop_index]) + 1
            run(executable, "-I", "ts-input", str(drop_position),
                "-i", HK_INTERFACE, "-s", cidr,
                "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED",
                "-j", "ACCEPT")
        else:
            for rule in scoped:
                run(executable, "-D", "ts-input", *rule)


def guard_if_hk_selected():
    selected = STATE_FILE.read_text(encoding="ascii").strip() if STATE_FILE.exists() else ""
    if selected == "hk":
        guard_tailnet(True)


def systemctl(action, unit="sing-box-tun.service"):
    run(SYSTEMCTL, action, unit)


def select(choice):
    if choice == "off":
        # Guard remains active until both TUNs stop and off is durable.
        systemctl("stop", HK_TUN)
        systemctl("stop", "sing-box-tun.service")
        save("off")
        tailnet_return_rule(False)
        hk_route(False)
        guard_tailnet(False)
        return

    if choice not in {"amane", "sachi", "hk"}:
        raise ValueError(f"invalid Asako proxy choice: {choice!r}")

    if choice == "hk":
        # Install the blackhole first. If rule-set startup fails before sing-box
        # creates its TUN, no native Tailscale route can bypass the guard.
        guard_tailnet(True)
        save("hk")
        systemctl("stop", "sing-box-tun.service")
        # Remove stale table state before bringing the interface back.
        hk_route(False)
        try:
            systemctl("start", HK_TUN)
            wait_for_hk_interface()
            tailnet_return_rule(True)
            hk_route(True)
        except Exception:
            # A failed start or partial route install must not leave a selector
            # rule pointing at a missing interface. Keep saved HK choice and
            # table-110 guard so failure stays closed until explicit recovery.
            hk_route(False)
            tailnet_return_rule(False)
            subprocess.run([SYSTEMCTL, "stop", HK_TUN])
            raise
        return

    # Keep the tailnet blackhole while stopping HK and selecting the new
    # Clash outbound. Any failure leaves the persisted HK state and guard.
    systemctl("stop", HK_TUN)
    tailnet_return_rule(False)

    systemctl("start")
    request = Request(
        f"{CLASH_API}/proxies/proxy",
        data=json.dumps({"name": choice}).encode("ascii"),
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    last_error = None
    for _ in range(CLASH_ATTEMPTS):
        try:
            with urlopen(request, timeout=2):
                pass
            save("on" if choice == "amane" else choice)
            hk_route(False)
            guard_tailnet(False)
            return
        except (URLError, TimeoutError) as error:
            last_error = error
            time.sleep(CLASH_RETRY_DELAY)
    raise RuntimeError(f"sing-box Clash API did not become ready: {last_error}")


def main(args):
    if args == ["guard"]:
        guard_if_hk_selected()
        return
    if len(args) == 1 and args[0] in {"off", "amane", "sachi", "hk", "on", "enable", "disable"}:
        select({"on": "amane", "enable": "amane", "disable": "off"}.get(args[0], args[0]))
    elif len(args) == 2 and args[0] == "restore" and args[1] in {"amane", "sachi", "hk", "off", "on"}:
        choice = STATE_FILE.read_text(encoding="ascii").strip() if STATE_FILE.exists() else args[1]
        select("amane" if choice == "on" else choice)
    else:
        raise SystemExit("usage: proxy-state.py off|amane|sachi|hk|restore amane|sachi|hk|off")


if __name__ == "__main__":
    main(sys.argv[1:])
