#!/usr/bin/env python3
"""Reconcile explicitly managed AAAA records without changing IPv4 DNS."""
import ipaddress
import json
import socket
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def request(token, path, method="GET", body=None):
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        "https://api.cloudflare.com/client/v4" + path,
        data=payload,
        method=method,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError(f"Cloudflare {method} failed: HTTP {error.code}") from None
    if not result.get("success"):
        raise RuntimeError("Cloudflare API rejected DNS reconciliation")
    return result["result"]


def public_address(config):
    interfaces = json.loads(subprocess.check_output(
        ["ip", "-j", "-6", "address", "show", "dev", config["interface"]]
    ))
    token = int(ipaddress.IPv6Address(config["interfaceIdentifier"]))
    addresses = []
    for interface in interfaces:
        for info in interface.get("addr_info", []):
            flags = info.get("flags", [])
            if any(info.get(flag) or flag in flags for flag in
                   ["temporary", "tentative", "dadfailed", "deprecated"]):
                continue
            address = ipaddress.IPv6Address(info["local"])
            if address.is_global and int(address) & ((1 << 64) - 1) == token:
                if info.get("preferred_life_time", 1) != 0:
                    addresses.append(str(address))
    if len(addresses) != 1:
        raise RuntimeError("Expected exactly one usable stable public IPv6 address")
    if not json.loads(subprocess.check_output(["ip", "-j", "-6", "route", "show", "default"])):
        raise RuntimeError("No IPv6 default route; public DNS update refused")
    address = addresses[0]
    # Prove native IPv6 egress and local HTTPS before publishing the origin.
    subprocess.run([
        "curl", "--fail", "--silent", "--show-error", "--ipv6", "--noproxy", "*",
        "--interface", address, "--connect-timeout", "10", "--max-time", "20",
        "https://www.cloudflare.com/cdn-cgi/trace",
    ], check=True, stdout=subprocess.DEVNULL)
    with socket.create_connection((address, 443), timeout=10) as connection:
        with ssl.create_default_context().wrap_socket(connection, server_hostname=config["probeHostname"]):
            pass
    return address


def reconcile(token, zone, record, address):
    query = urllib.parse.urlencode({"type": "AAAA", "name": record["name"]})
    existing = request(token, f"/zones/{zone}/dns_records?{query}")
    if len(existing) > 1:
        raise RuntimeError("Multiple AAAA records exist for " + record["name"])
    comment = "nixfiles-native-ipv6"
    if existing and existing[0].get("comment") != comment:
        raise RuntimeError("Unmanaged AAAA record exists for " + record["name"])
    body = {
        "type": "AAAA", "name": record["name"], "content": address,
        "proxied": record.get("proxied", False), "ttl": record.get("ttl", 1), "comment": comment,
    }
    if existing:
        current = existing[0]
        if all(current.get(key) == value for key, value in body.items()):
            return
        request(token, f"/zones/{zone}/dns_records/{current['id']}", "PATCH", body)
    else:
        request(token, f"/zones/{zone}/dns_records", "POST", body)
    print("Updated AAAA:", record["name"], flush=True)


def remove_managed(token, zone, record):
    query = urllib.parse.urlencode({"type": "AAAA", "name": record["name"]})
    for current in request(token, f"/zones/{zone}/dns_records?{query}"):
        if current.get("comment") == "nixfiles-native-ipv6":
            request(token, f"/zones/{zone}/dns_records/{current['id']}", "DELETE")
            print("Removed managed AAAA:", record["name"], flush=True)


def main():
    config = json.loads(Path(sys.argv[1]).read_text())
    token = Path(config["tokenFile"]).read_text().strip()
    zones = request(token, "/zones?name=" + urllib.parse.quote(config["zone"]))
    if len(zones) != 1:
        raise RuntimeError("Expected exactly one authorized Cloudflare zone")
    zone = zones[0]["id"]
    if len(sys.argv) > 2:
        if sys.argv[2] != "--rollback":
            raise RuntimeError("Unknown action")
        for record in config.get("publicRecords", []) + config.get("staticRecords", []):
            remove_managed(token, zone, record)
        return
    # Tailnet AAAA is independent of public ISP address availability.
    for record in config.get("staticRecords", []):
        address = ipaddress.IPv6Address(record["address"])
        if address not in ipaddress.IPv6Network("fd7a:115c:a1e0::/48"):
            raise RuntimeError("Private record must use verified Tailscale IPv6")
        reconcile(token, zone, record, str(address))
    if config.get("publicRecords"):
        try:
            address = public_address(config)
        except (RuntimeError, OSError, subprocess.CalledProcessError):
            # Withdraw our public AAAA when IPv6 fails, preserving IPv4 fallback.
            for record in config["publicRecords"]:
                remove_managed(token, zone, record)
            raise
        for record in config["publicRecords"]:
            reconcile(token, zone, record, address)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print("IPv6 DNS update failed:", error, file=sys.stderr)
        sys.exit(1)
