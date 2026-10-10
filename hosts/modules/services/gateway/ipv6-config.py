#!/usr/bin/env python3
"""Include current LAN IPv6 prefixes in existing Traefik access rules."""
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

base, output, interface, ip_command = sys.argv[1:]
config = json.loads(Path(base).read_text())
prefixes = set()
if interface != "-":
    try:
        links = json.loads(subprocess.check_output([ip_command, "-j", "-6", "address", "show", "dev", interface]))
    except (subprocess.CalledProcessError, FileNotFoundError):
        # A roaming host may have no trusted LAN interface at boot. Regenerate
        # from the base allowlists so a previously learned prefix is removed.
        links = []
    for link in links:
        for info in link.get("addr_info", []):
            try:
                address = ipaddress.IPv6Address(info["local"])
                network = ipaddress.IPv6Network((address, info["prefixlen"]), strict=False)
            except (KeyError, TypeError, ValueError):
                continue
            flags = set(info.get("flags", []))
            invalid = {"tentative", "dadfailed", "deprecated"}
            if address.is_global and not (flags & invalid) and not any(info.get(flag) for flag in invalid):
                prefixes.add(str(network))
for name in ["lan-only", "wan"]:
    config["http"]["middlewares"][name]["ipAllowList"]["sourceRange"] += sorted(prefixes)
destination = Path(output)
content = json.dumps(config, sort_keys=True) + "\n"
if not destination.exists() or destination.read_text() != content:
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, prefix=".dynamic-ipv6-", delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(content)
    try:
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
