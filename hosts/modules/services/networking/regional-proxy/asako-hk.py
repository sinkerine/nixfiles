#!/usr/bin/env python3
"""Render Asako's HK TUN config from its root-only runtime profile."""

import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import socket
import tempfile
import sys


def render(profile_path, android_profiles_path):
    spec = importlib.util.spec_from_file_location("asako_android_profiles", android_profiles_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with open(profile_path, encoding="utf-8") as source:
        profile = json.load(source)
    config = module.hk_profile(profile)
    # LAN DNS can bypass the TUN on Linux. Recover HTTP/TLS hostnames before
    # domain rules so home-service and manual US overrides still take effect.
    config["route"]["rules"].insert(0, {"action": "sniff"})
    # Resolve the relay and remote rule-set hosts with the system resolver.
    # A numeric bootstrap DNS server with no detour follows route.final, which
    # is HK-direct; resolving the HK relay that way can recurse through itself.
    config["dns"]["servers"] = [
        server for server in config["dns"].get("servers", [])
        if server.get("tag") != "bootstrap"
    ]
    config["route"]["default_domain_resolver"] = "local-dns"
    config["inbounds"][0]["interface_name"] = "singtun-hk0"
    tailnet_ipv6 = ipaddress.ip_network("fd7a:115c:a1e0::/48")
    excluded_addresses = [
        "10.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16",
        "172.16.0.0/12", "192.168.0.0/16", "fe80::/10",
    ]
    # Preserve ULA exclusions while allowing the tailnet range through HK.
    excluded_addresses.extend(
        str(network)
        for network in ipaddress.ip_network("fd00::/8").address_exclude(tailnet_ipv6)
    )
    # With strict TUN routing, explicitly bypass every resolved relay address;
    # otherwise VLESS's own TCP connection can be captured by its TUN.
    relay_addresses = {
        ipaddress.ip_address(result[4][0].split("%", 1)[0])
        for result in socket.getaddrinfo(
            profile["host"], int(profile["port"]), type=socket.SOCK_STREAM
        )
    }
    excluded_addresses.extend(
        f"{address}/{32 if address.version == 4 else 128}"
        for address in sorted(relay_addresses, key=lambda item: (item.version, int(item)))
    )
    config["inbounds"][0]["route_exclude_address"] = excluded_addresses
    return config


def main(args):
    if len(args) != 3:
        raise SystemExit("usage: asako-hk.py PROFILE_JSON OUTPUT_JSON ANDROID_PROFILES_PY")
    config = render(args[0], args[2])
    output_dir = os.path.dirname(args[1]) or "."
    fd, temporary = tempfile.mkstemp(dir=output_dir, prefix=".asako-hk.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(config, output, indent=2)
            output.write("\n")
        os.chmod(temporary, 0o600)
        os.replace(temporary, args[1])
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    main(sys.argv[1:])
