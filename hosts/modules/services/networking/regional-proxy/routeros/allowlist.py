#!/usr/bin/env python3
"""Render and apply RouterOS HK domain allowlists without GeoIP sources."""

import argparse
import ipaddress
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
LIST = "regional-hk-allowlist"
COMMENT = "regional-hk-owned"


def domains(path):
    result = set()
    for number, line in enumerate(path.read_text().splitlines(), 1):
        value = line.split("#", 1)[0].strip().lower().rstrip(".")
        if not value:
            continue
        try:
            value = value.encode("idna").decode("ascii")
        except UnicodeError as error:
            raise ValueError(f"line {number}: invalid domain") from error
        try:
            ipaddress.ip_address(value)
        except ValueError:
            pass
        else:
            raise ValueError(f"line {number}: IP addresses are not allowed")
        labels = value.split(".")
        if (len(value) > 253 or len(labels) < 2
                or not all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) for label in labels)
                or not re.search(r"[a-z]", labels[-1])):
            raise ValueError(f"line {number}: expected domain, no URL, wildcard or CIDR")
        if value == "mado.moe" or value.endswith(".mado.moe") or value == "weixin.qq.com" or value.endswith(".weixin.qq.com"):
            raise ValueError(f"line {number}: domain is covered by a permanent WAN exclusion")
        result.add(value)
    return sorted(result)


def render(names, disabled=True):
    state = "yes" if disabled else "no"
    return [f'/ip dns static add name="{name}" type=FWD forward-to=172.31.241.1 '
            f'match-subdomain=yes address-list={LIST} disabled={state} comment="{COMMENT}"'
            for name in names]


def ssh(target, command):
    result = subprocess.run(["ssh", target, command], text=True, capture_output=True, timeout=120)
    output = result.stdout.replace("\r", "").strip()
    if result.returncode or re.search(r"failure:|syntax error|no such item|expected end of command|Script Error", output, re.I):
        raise RuntimeError(result.stderr.strip() or output or "RouterOS SSH failed")
    return output


def apply(names, target):
    marker = '[find where comment="regional-hk-owned" and action="mark-connection"]'
    route_marker = '[find where comment="regional-hk-owned" and action="mark-routing"]'
    for description, command, expected in [
        ("WireGuard interface", '/interface wireguard print count-only where name="wg-regional-hk"', "1"),
        ("connection marking rule", '/ip firewall mangle print count-only where comment="regional-hk-owned" and action="mark-connection"', "1"),
        ("routing marking rule", '/ip firewall mangle print count-only where comment="regional-hk-owned" and action="mark-routing"', "1"),
        
    ]:
        if ssh(target, command) != expected:
            raise RuntimeError(f"unexpected {description}; no configuration changed")
    if ssh(target, ':put [/ip dns get address-list-extra-time]') not in ("0s", "00:00:00"):
        raise RuntimeError("DNS address-list-extra-time must be zero; no configuration changed")
    active = ssh(target, ':put [/interface wireguard get [find where name="wg-regional-hk"] disabled]')
    if active not in ("true", "false", "yes", "no"):
        raise RuntimeError("unexpected tunnel state; no configuration changed")
    enabled = active in ("false", "no")
    # Stop new HK classification before removing stale lists and marked sessions.
    # Failure leaves classification disabled; rerunning apply is idempotent.
    ssh(target, '/ip firewall mangle disable ' + marker + '; /ip firewall mangle disable ' + route_marker)
    ssh(target, ':foreach c in=[/ip firewall connection find where connection-mark="regional-hk-cn"] do={ :do { /ip firewall connection remove $c } on-error={} }')
    ssh(target, '/ip firewall mangle set ' + marker + ' dst-address-list=' + LIST)
    ssh(target, '/ip dns static remove [find where comment="regional-hk-owned" and address-list="regional-hk-cn"]; '
        '/ip dns static remove [find where comment="regional-hk-owned" and address-list="regional-hk-allowlist"]; '
        '/ip firewall address-list remove [find where list="regional-hk-cn"]; '
        '/ip firewall address-list remove [find where list="regional-hk-allowlist"]')
    for row in render(names, disabled=not enabled):
        ssh(target, row)
    ssh(target, '/ip dns cache flush')
    count = ssh(target, '/ip dns static print count-only where comment="regional-hk-owned" and address-list="regional-hk-allowlist"')
    if count != str(len(names)):
        raise RuntimeError("allowlist import count mismatch; classification remains disabled")
    if ssh(target, '/ip firewall address-list print count-only where list="regional-hk-cn"') != "0":
        raise RuntimeError("old China address list remains; classification remains disabled")
    if enabled:
        ssh(target, '/ip firewall mangle enable ' + marker + '; /ip firewall mangle enable ' + route_marker)
    print(f"Applied {len(names)} allowlisted domains; GeoIP removed; proxy {'ON' if enabled else 'OFF'}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("render", "apply"))
    parser.add_argument("--file", type=Path, default=Path(os.environ.get("REGIONAL_PROXY_ALLOWLIST", ROOT / "domains.txt")))
    parser.add_argument("--router", default=os.environ.get("ROUTEROS_SSH_TARGET", "router"))
    args = parser.parse_args()
    try:
        names = domains(args.file)
        if args.action == "render":
            for row in render(names):
                print(row)
        else:
            apply(names, args.router)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"allowlist failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
