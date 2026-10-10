#!/usr/bin/env python3
"""Export local sing-box Android profiles without storing client secrets in Nix."""

import json
import os
import sys
import tempfile


SERVERS = {
    "amane": {
        "host": "167.148.6.201",
        "normal_port": 10087,
        "normal_key": "IM4pgDQbcql0ZIrzUWeU0HKE8GWbqsAV1t3c-PC20ks",
        "normal_short_id": "a1b2c3d4",
        "paypal_port": 10088,
        "paypal_key": "IM4pgDQbcql0ZIrzUWeU0HKE8GWbqsAV1t3c-PC20ks",
        "paypal_short_id": "8c614ced",
    },
    "sachi": {
        "host": "mado.moe",
        "lan_host": "192.168.88.30",
        "normal_port": 10087,
        "normal_key": "-6pvY7DzL_M7q-7fNeZZrnxosjIFyNPltVCo4rFu1yo",
        "normal_short_id": "e5f60718",
        "paypal_port": 10089,
        "paypal_key": "-6pvY7DzL_M7q-7fNeZZrnxosjIFyNPltVCo4rFu1yo",
        "paypal_short_id": "27323628",
    },
}
MICHIRU_PROXY_HOST = "103.117.101.12"

LAN_DIRECT_CIDRS = [
    "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
    "172.16.0.0/12", "192.168.0.0/16", "fc00::/7", "fe80::/10",
]


def profile(uuid, server_name, mode, tailnet=False, tailnet_auth_key=None):
    server = SERVERS[server_name]
    paypal = mode == "paypal"
    rules = [{"protocol": "dns", "action": "hijack-dns"}]
    if tailnet:
        rules.extend([
            {"action": "sniff"},
            {"domain": ["headscale.mado.moe"], "action": "route", "outbound": "direct" if server_name == "sachi" else "proxy"},
            # Sachi's Docker subnet is reachable through its advertised exit route.
            {"ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "172.16.0.0/16"], "action": "route", "outbound": "tailscale"},
        ])
    rules.extend([
        {"ip_cidr": LAN_DIRECT_CIDRS, "action": "route", "outbound": "direct"},
        {"ip_is_private": True, "action": "route", "outbound": "direct"},
    ])
    rule_sets = []
    if not paypal:
        rules.extend([
            {"rule_set": ["geosite-cn"], "action": "route", "outbound": "direct"},
            {"rule_set": ["geoip-cn"], "action": "route", "outbound": "direct"},
        ])
        rule_sets = [
            {"tag": "geosite-cn", "type": "remote", "format": "binary", "url": "https://github.com/SagerNet/sing-geosite/raw/rule-set/geosite-cn.srs", "http_client": "rule-set-via-proxy"},
            {"tag": "geoip-cn", "type": "remote", "format": "binary", "url": "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-cn.srs", "http_client": "rule-set-via-proxy"},
        ]
    tag = "proxy"
    outbound = {
        "type": "vless",
        "tag": tag,
        "server": server["host"],
        "server_port": server["paypal_port"] if paypal else server["normal_port"],
        "uuid": uuid,
        "flow": "xtls-rprx-vision",
        "tls": {
            "enabled": True,
            "server_name": "www.paypal.com" if paypal else "www.cloudflare.com",
            "utls": {"enabled": True, "fingerprint": "chrome"},
            "reality": {
                "enabled": True,
                "public_key": server["paypal_key"] if paypal else server["normal_key"],
                "short_id": server["paypal_short_id"] if paypal else server["normal_short_id"],
            },
        },
    }
    if server_name == "sachi":
        public_outbound = {**outbound, "tag": "sachi-public"}
        lan_outbound = {**outbound, "tag": "sachi-lan", "server": server["lan_host"]}
        proxy_outbounds = [
            lan_outbound,
            public_outbound,
            {
                "type": "urltest",
                "tag": tag,
                "outbounds": ["sachi-lan", "sachi-public"],
                "interval": "10s",
            },
        ]
    else:
        proxy_outbounds = [outbound]
    result = {
        "log": {"level": "warn"},
        "dns": {
            "servers": [
                {"type": "udp", "tag": "bootstrap", "server": "9.9.9.9", "detour": "direct"},
                {"type": "https", "tag": "remote-dns", "server": "1.1.1.1", "path": "/dns-query", "detour": "proxy"},
            ],
            "final": "remote-dns",
            "strategy": "prefer_ipv4",
        },
        # Keep TUN addresses inside the VPN route. SFA protects outbound sockets;
        # the LAN CIDR rule above sends local destinations through direct.
        "inbounds": [
            {
                "type": "tun",
                "tag": "tun-in",
                "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                "mtu": 9000,
                "auto_route": True,
                "strict_route": True,
            }
        ],
        "outbounds": proxy_outbounds + [{"type": "direct", "tag": "direct", "connect_timeout": "5s"}],
        "http_clients": [{"tag": "rule-set-via-proxy", "detour": "proxy"}],
        "route": {
            "final": "proxy",
            "auto_detect_interface": True,
            "default_domain_resolver": "bootstrap",
            "rules": rules,
            "rule_set": rule_sets,
        },
    }
    if tailnet:
        result["dns"]["reverse_mapping"] = True
        if server_name == "sachi":
            # Sachi's LAN DNS returns its private address. Resolving through
            # the proxy returns the public address and reaches the router's
            # TLS service instead of Headscale on this LAN.
            result["dns"]["servers"].insert(0, {"type": "local", "tag": "lan-dns"})
            result["dns"]["rules"] = [{"domain": ["headscale.mado.moe"], "server": "lan-dns"}]
        endpoint = {
            "type": "tailscale",
            "tag": "tailscale",
            # Keep independent Headscale identities for the Amane and Sachi
            # profiles. Variants for the same server share registration state.
            "state_directory": f"tailscale-{server_name}",
            "hostname": f"makina-{server_name}",
            "control_url": "https://headscale.mado.moe",
            "detour": "direct" if server_name == "sachi" else "proxy",
            "accept_routes": True,
            "exit_node": "sachi",
            "exit_node_allow_lan_access": True,
        }
        if server_name == "sachi":
            endpoint["domain_resolver"] = "lan-dns"
        if tailnet_auth_key:
            endpoint["auth_key"] = tailnet_auth_key
        result["endpoints"] = [endpoint]
    return result


def hk_profile(config, tailnet_auth_key=None):
    required = ("host", "port", "direct_uuid", "us_uuid", "public_key", "short_id")
    missing = [key for key in required if key not in config]
    if missing:
        raise ValueError("HK profile config missing: " + ", ".join(missing))
    # Keep proxy credentials and TLS parameters in the encrypted config while
    # pinning the relay address used by Makina's exported profile.
    host, port = MICHIRU_PROXY_HOST, config["port"]

    def vless(tag, uuid, server=host, server_port=port):
        return {
            "type": "vless", "tag": tag, "server": server, "server_port": server_port,
            "uuid": uuid, "flow": "xtls-rprx-vision",
            "tls": {"enabled": True, "server_name": "www.cloudflare.com",
                    "utls": {"enabled": True, "fingerprint": "chrome"},
                    "reality": {"enabled": True, "public_key": config["public_key"],
                                "short_id": config["short_id"]}},
        }

    rules = [
        {"protocol": "dns", "action": "hijack-dns"},
        {"domain_suffix": ["mado.moe"], "action": "route", "outbound": "hk-direct"},
        {"ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "172.16.0.0/16"], "action": "route", "outbound": "tailscale"},
        {"ip_is_private": True, "action": "route", "outbound": "direct"},
        {"rule_set": ["geosite-cn"], "action": "route", "outbound": "direct"},
        {"rule_set": ["geoip-cn"], "action": "route", "outbound": "direct"},
        {"rule_set": ["geoip-us"], "action": "route", "outbound": "hk-us"},
    ]
    manual_us_domains = config.get("us_domains", [])
    if manual_us_domains:
        # Domain matches must win before destination-IP GeoIP rules.
        rules.insert(5, {"domain": manual_us_domains, "action": "route", "outbound": "hk-us"})
    sets = []
    for tag, url in (
        ("geosite-cn", "https://github.com/SagerNet/sing-geosite/raw/rule-set/geosite-cn.srs"),
        ("geoip-cn", "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-cn.srs"),
        ("geoip-us", "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-us.srs"),
    ):
        sets.append({"tag": tag, "type": "remote", "format": "binary", "url": url,
                     "http_client": "rule-set-via-hk-direct"})
    endpoint = {
        "type": "tailscale",
        "tag": "tailscale",
        # Reuse Makina's existing Sachi tailnet identity across these mutually
        # exclusive SFA profiles, avoiding a new Headscale credential/device.
        "state_directory": "tailscale-sachi",
        "hostname": "makina-sachi",
        "control_url": "https://headscale.mado.moe",
        "detour": "hk-direct",
        "domain_resolver": "managed-dns",
        "accept_routes": True,
        "exit_node": "sachi",
        "exit_node_allow_lan_access": True,
    }
    if tailnet_auth_key:
        endpoint["auth_key"] = tailnet_auth_key
    return {
        "log": {"level": "warn"},
        "dns": {"servers": [
            {"type": "local", "tag": "local-dns"},
            {"type": "udp", "tag": "bootstrap", "server": "9.9.9.9", "detour": "direct"},
            {"type": "https", "tag": "managed-dns", "server": "1.1.1.1", "path": "/dns-query", "detour": "hk-direct"},
        ], "rules": [
            {"domain_suffix": ["mado.moe"], "server": "managed-dns"},
            {"rule_set": ["geosite-cn"], "server": "local-dns"},
        ], "final": "managed-dns", "strategy": "ipv4_only", "reverse_mapping": True},
        "inbounds": [{"type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
                       "mtu": 9000, "auto_route": True, "strict_route": True}],
        "endpoints": [endpoint],
        "outbounds": [vless("hk-direct", config["direct_uuid"]),
                      vless("hk-us", config["us_uuid"]),
                      # SFA 1.14.2 rejects detours to a direct outbound without
                      # an explicit timeout (for example managed DNS bootstrap).
                      {"type": "direct", "tag": "direct", "connect_timeout": "5s"}],
        "http_clients": [{"tag": "rule-set-via-hk-direct", "detour": "hk-direct"}],
        "route": {"final": "hk-direct", "auto_detect_interface": True,
                  "default_domain_resolver": "bootstrap", "rules": rules, "rule_set": sets},
    }



def generate(secret_path, output_dir, tailnet_auth_keys=None):
    with open(secret_path, encoding="ascii") as secret:
        uuid = secret.read().strip()
    if not uuid:
        raise ValueError("SOPS client UUID file is empty")

    hk_config_path = os.environ.get("MICHIRU_PROFILE_CONFIG_FILE")
    if not hk_config_path:
        raise ValueError("MICHIRU_PROFILE_CONFIG_FILE is required")
    with open(hk_config_path, encoding="utf-8") as source:
        hk_config = hk_profile(json.load(source), (tailnet_auth_keys or {}).get("michiru-cn-direct-tailscale"))

    os.makedirs(output_dir, mode=0o700, exist_ok=True)
    paths = []
    keys = tailnet_auth_keys or {}
    for server_name in SERVERS:
        for mode, suffix in (("normal", ""), ("paypal", "-paypal")):
            name = f"{server_name}{suffix}-tailscale"
            path = os.path.join(output_dir, f"{name}.json")
            fd, temporary = tempfile.mkstemp(dir=output_dir, prefix=f".{name}.", suffix=".tmp")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as output:
                    json.dump(profile(uuid, server_name, mode, True, keys.get(name)), output, indent=2)
                    output.write("\n")
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            paths.append(path)
    path = os.path.join(output_dir, "michiru-cn-direct-tailscale.json")
    fd, temporary = tempfile.mkstemp(dir=output_dir, prefix=".michiru-cn.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(hk_config, output, indent=2)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    paths.append(path)

    # Remove only the exact legacy profile files this generator used to emit.
    obsolete = {
        filename
        for server in SERVERS
        for filename in (
            f"{server}-normal.json",
            f"{server}-normal-tailscale.json",
            f"{server}-paypal.json",
        )
    } | {"michiru-cn.json"}
    for name in obsolete:
        try:
            os.unlink(os.path.join(output_dir, name))
        except FileNotFoundError:
            pass
    return paths


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: android-profiles.py SOPS_UUID_FILE OUTPUT_DIRECTORY [HEADSCALE_AUTH_KEYS_JSON]")
    auth_keys = None
    if len(sys.argv) == 4:
        with open(sys.argv[3], encoding="ascii") as source:
            auth_keys = json.load(source)
    for path in generate(sys.argv[1], sys.argv[2], auth_keys):
        print(path)
