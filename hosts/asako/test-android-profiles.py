import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


spec = importlib.util.spec_from_file_location("android_profiles", Path(__file__).parents[1] / "makina" / "android-profiles.py")
android_profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android_profiles)
state_path = Path(__file__).with_name("proxy-state.py")


class AndroidProfileTests(unittest.TestCase):
    def test_optional_makina_hk_profile_and_route_precedence(self):
        profile_config = {
            "host": "hk.example.net", "port": 443,
            "direct_uuid": "11111111-1111-4111-8111-111111111111",
            "us_uuid": "22222222-2222-4222-8222-222222222222",
            "public_key": "public-key", "short_id": "abcd1234",
            "us_domains": ["example.com", "example.org"],
        }
        uuid = "00000000-0000-4000-8000-000000000000"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            secret = root / "uuid"
            secret.write_text(uuid, encoding="ascii")
            config_path = root / "hk.json"
            config_path.write_text(json.dumps(profile_config), encoding="utf-8")
            output = root / "profiles"
            old = os.environ.get("MICHIRU_PROFILE_CONFIG_FILE")
            os.environ["MICHIRU_PROFILE_CONFIG_FILE"] = str(config_path)
            try:
                paths = android_profiles.generate(secret, output)
            finally:
                if old is None:
                    os.environ.pop("MICHIRU_PROFILE_CONFIG_FILE", None)
                else:
                    os.environ["MICHIRU_PROFILE_CONFIG_FILE"] = old
            self.assertEqual(len(paths), 5)
            config = json.loads((output / "michiru-cn-direct-tailscale.json").read_text())
            self.assertEqual(config["dns"]["strategy"], "ipv4_only")
            self.assertEqual(config["dns"]["final"], "managed-dns")
            dns_servers = {server["tag"]: server for server in config["dns"]["servers"]}
            self.assertEqual(dns_servers["managed-dns"]["detour"], "hk-direct")
            self.assertEqual(dns_servers["local-dns"]["type"], "local")
            self.assertEqual(config["dns"]["rules"], [
                {"domain_suffix": ["mado.moe"], "server": "managed-dns"},
                {"rule_set": ["geosite-cn"], "server": "local-dns"},
            ])
            self.assertEqual(config["inbounds"][0]["address"], ["172.19.0.1/30"])
            self.assertEqual(config["endpoints"], [{
                "type": "tailscale", "tag": "tailscale", "state_directory": "tailscale-sachi",
                "hostname": "makina-sachi", "control_url": "https://headscale.mado.moe",
                "detour": "hk-direct", "domain_resolver": "managed-dns", "accept_routes": True,
                "exit_node": "sachi", "exit_node_allow_lan_access": True,
            }])
            self.assertEqual([(x["tag"], x["uuid"]) for x in config["outbounds"][:2]], [
                ("hk-direct", profile_config["direct_uuid"]), ("hk-us", profile_config["us_uuid"]),
            ])
            self.assertEqual([x["server"] for x in config["outbounds"][:2]], [
                "103.117.101.12", "103.117.101.12",
            ])
            self.assertEqual(config["outbounds"][2], {
                "type": "direct", "tag": "direct", "connect_timeout": "5s",
            })
            rules = config["route"]["rules"]
            self.assertEqual(rules[1], {"domain_suffix": ["mado.moe"], "action": "route", "outbound": "hk-direct"})
            self.assertEqual(rules[2], {"ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "172.16.0.0/16"], "action": "route", "outbound": "tailscale"})
            self.assertEqual(rules[4]["rule_set"], ["geosite-cn"])
            self.assertEqual(rules[5], {"domain": profile_config["us_domains"], "action": "route", "outbound": "hk-us"})
            self.assertEqual(rules[6]["rule_set"], ["geoip-cn"])
            self.assertEqual(rules[7], {"rule_set": ["geoip-us"], "action": "route", "outbound": "hk-us"})
            self.assertEqual(config["route"]["final"], "hk-direct")
            self.assertTrue(all(item["http_client"] == "rule-set-via-hk-direct" for item in config["route"]["rule_set"]))

    def test_json_exports_preserve_routing_modes(self):
        uuid = "00000000-0000-4000-8000-000000000000"
        with tempfile.TemporaryDirectory() as temp:
            secret_path = Path(temp) / "uuid"
            secret_path.write_text(uuid, encoding="ascii")
            hk_config_path = Path(temp) / "hk.json"
            hk_config_path.write_text(json.dumps({
                "host": "hk.example.net", "port": 443,
                "direct_uuid": "11111111-1111-4111-8111-111111111111",
                "us_uuid": "22222222-2222-4222-8222-222222222222",
                "public_key": "public-key", "short_id": "abcd1234", "us_domains": [],
            }), encoding="utf-8")
            profile_env = patch.dict(os.environ, {"MICHIRU_PROFILE_CONFIG_FILE": str(hk_config_path)})
            profile_env.start()
            self.addCleanup(profile_env.stop)
            output_dir = Path(temp) / "profiles"
            paths = [Path(path) for path in android_profiles.generate(secret_path, output_dir)]
            expected = {
                f"{server}{suffix}-tailscale.json"
                for server in android_profiles.SERVERS
                for suffix in ("", "-paypal")
            } | {"michiru-cn-direct-tailscale.json"}
            self.assertEqual({path.name for path in paths}, expected)
            for path in paths:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

            for server_name in android_profiles.SERVERS:
                for mode, suffix in (("normal", ""), ("paypal", "-paypal")):
                        name = f"{server_name}{suffix}-tailscale"
                        config = json.loads((output_dir / f"{name}.json").read_text())
                        self.assertEqual(config["route"]["final"], "proxy")
                        self.assertNotIn("route_exclude_address", config["inbounds"][0])
                        self.assertIn(
                            {"ip_cidr": android_profiles.LAN_DIRECT_CIDRS, "action": "route", "outbound": "direct"},
                            config["route"]["rules"],
                        )
                        self.assertEqual(config["endpoints"], [{
                                "type": "tailscale", "tag": "tailscale", "state_directory": f"tailscale-{server_name}",
                                "hostname": f"makina-{server_name}",
                                "control_url": "https://headscale.mado.moe", "detour": "direct" if server_name == "sachi" else "proxy", "accept_routes": True,
                                "exit_node": "sachi", "exit_node_allow_lan_access": True,
                                **({"domain_resolver": "lan-dns"} if server_name == "sachi" else {}),
                            }])
                        self.assertEqual(config["route"]["rules"][1:4], [
                                {"action": "sniff"},
                                {"domain": ["headscale.mado.moe"], "action": "route", "outbound": "direct" if server_name == "sachi" else "proxy"},
                                {"ip_cidr": ["100.64.0.0/10", "fd7a:115c:a1e0::/48", "172.16.0.0/16"], "action": "route", "outbound": "tailscale"},
                        ])
                        if server_name == "sachi":
                            self.assertIn({"type": "local", "tag": "lan-dns"}, config["dns"]["servers"])
                            self.assertEqual(config["dns"]["rules"], [{"domain": ["headscale.mado.moe"], "server": "lan-dns"}])
                        self.assertTrue(config["dns"]["reverse_mapping"])
                        direct = next(item for item in config["outbounds"] if item["tag"] == "direct")
                        self.assertEqual(direct["connect_timeout"], "5s")
                        self.assertEqual(config["dns"]["final"], "remote-dns")
                        dns = {item["tag"]: item for item in config["dns"]["servers"]}
                        self.assertEqual(dns["remote-dns"]["detour"], "proxy")
                        self.assertEqual(config["route"]["default_domain_resolver"], "bootstrap")
                        server = android_profiles.SERVERS[server_name]
                        if server_name == "sachi":
                            outbound = next(item for item in config["outbounds"] if item["tag"] == "sachi-public")
                            local_outbound = next(item for item in config["outbounds"] if item["tag"] == "sachi-lan")
                            proxy = next(item for item in config["outbounds"] if item["tag"] == "proxy")
                            self.assertEqual(proxy["type"], "urltest")
                            self.assertEqual(proxy["outbounds"], ["sachi-lan", "sachi-public"])
                            self.assertEqual(local_outbound["server"], server["lan_host"])
                        else:
                            outbound = next(item for item in config["outbounds"] if item["tag"] == "proxy")
                        self.assertEqual(outbound["server"], server["host"])
                        self.assertEqual(outbound["uuid"], uuid)
                        if mode == "paypal":
                            self.assertEqual(outbound["server_port"], server["paypal_port"])
                            self.assertEqual(outbound["tls"]["server_name"], "www.paypal.com")
                            self.assertFalse(config["route"]["rule_set"])
                            self.assertFalse(any("cn" in json.dumps(rule).lower() for rule in config["route"]["rules"]))
                        else:
                            self.assertEqual(outbound["server_port"], server["normal_port"])
                            self.assertEqual(outbound["tls"]["server_name"], "www.cloudflare.com")
                            self.assertEqual(len(config["route"]["rule_set"]), 2)
                            self.assertTrue(all(item["http_client"] == "rule-set-via-proxy" for item in config["route"]["rule_set"]))
                            self.assertEqual(config["http_clients"], [{"tag": "rule-set-via-proxy", "detour": "proxy"}])

            keys = {
                "amane-tailscale": "amane-test-key",
                "michiru-cn-direct-tailscale": "sachi-test-key",
            }
            android_profiles.generate(secret_path, output_dir, keys)
            authorized = json.loads((output_dir / "amane-tailscale.json").read_text())
            self.assertEqual(authorized["endpoints"][0]["auth_key"], "amane-test-key")
            other = json.loads((output_dir / "sachi-tailscale.json").read_text())
            self.assertNotIn("auth_key", other["endpoints"][0])
            michiru = json.loads((output_dir / "michiru-cn-direct-tailscale.json").read_text())
            self.assertEqual(michiru["endpoints"][0]["auth_key"], "sachi-test-key")


class ProxyStateTests(unittest.TestCase):
    def setUp(self):
        # Never query or mutate the test host's real firewall. Model Tailscale's
        # IPv4 anti-spoof drop and its IPv6 chain, which has no matching drop.
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        firewall = Path(temporary.name) / "iptables"
        firewall.write_text(
            '#!/bin/sh\n'
            'if [ "$1" = "-S" ]; then\n'
            '  echo "-N ts-input"\n'
            '  echo "-A ts-input -i tailscale0 -j ACCEPT"\n'
            '  case "$0" in *ip6tables) ;; *) echo "-A ts-input -s 100.64.0.0/10 ! -i tailscale0 -j DROP" ;; esac\n'
            'fi\n'
        )
        firewall.chmod(0o755)
        firewall6 = firewall.with_name("ip6tables")
        firewall6.symlink_to(firewall)
        environment = patch.dict(os.environ, {
            "ASAKO_IPTABLES": str(firewall), "ASAKO_IP6TABLES": str(firewall6),
        })
        environment.start()
        self.addCleanup(environment.stop)

    def test_toggle_persists_and_boot_restore_honors_choice(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state_dir = root / "state"
            calls = root / "systemctl.log"
            fake_systemctl = root / "systemctl"
            fake_systemctl.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n", encoding="utf-8")
            fake_systemctl.chmod(0o755)
            fake_ip = root / "ip"
            fake_ip.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            fake_ip.chmod(0o755)
            env = dict(os.environ, ASAKO_PROXY_STATE_DIR=str(state_dir), ASAKO_SYSTEMCTL=str(fake_systemctl), ASAKO_IP=str(fake_ip), CALL_LOG=str(calls))

            def run(*args):
                subprocess.run(["python3", str(state_path), *args], env=env, check=True)

            run("hk")
            self.assertEqual((state_dir / "state").read_text().strip(), "hk")
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-tun.service", "start sing-box-hk-tun.service"])
            calls.unlink()
            run("restore", "off")
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-tun.service", "start sing-box-hk-tun.service"])

            calls.unlink()
            run("off")
            self.assertEqual((state_dir / "state").read_text().strip(), "off")
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-hk-tun.service", "stop sing-box-tun.service"])
            calls.unlink()
            run("restore", "off")
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-hk-tun.service", "stop sing-box-tun.service"])

    def test_hk_switch_keeps_guard_and_stops_other_tun(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            calls = root / "systemctl.log"
            fake_systemctl = root / "systemctl"
            fake_systemctl.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n", encoding="utf-8")
            fake_systemctl.chmod(0o755)
            ip_calls = root / "ip.log"
            fake_ip = root / "ip"
            fake_ip.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$IP_LOG\"\n", encoding="utf-8")
            fake_ip.chmod(0o755)
            env = dict(os.environ, ASAKO_PROXY_STATE_DIR=str(root / "state"), ASAKO_SYSTEMCTL=str(fake_systemctl),
                       ASAKO_IP=str(fake_ip), CALL_LOG=str(calls), IP_LOG=str(ip_calls))
            subprocess.run(["python3", str(state_path), "hk"], env=env, check=True)
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-tun.service", "start sing-box-hk-tun.service"])
            self.assertEqual((root / "state" / "state").read_text().strip(), "hk")
            routes = ip_calls.read_text()
            self.assertIn("route replace blackhole 100.64.0.0/10 table 110", routes)
            self.assertIn("rule add priority 1001 iif lo to 100.64.0.0/10 lookup 110", routes)
            self.assertIn("rule add priority 1000 iif lo to 100.64.0.0/10 lookup 109", routes)
            calls.unlink()
            subprocess.run(["python3", str(state_path), "off"], env=env, check=True)
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-hk-tun.service", "stop sing-box-tun.service"])
            self.assertIn("route del blackhole 100.64.0.0/10 table 110", ip_calls.read_text())

    def test_failed_clash_switch_leaves_saved_hk_guard_installed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state_dir = root / "state"
            state_dir.mkdir()
            (state_dir / "state").write_text("hk\n", encoding="ascii")
            calls = root / "systemctl.log"
            fake_systemctl = root / "systemctl"
            fake_systemctl.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n", encoding="utf-8")
            fake_systemctl.chmod(0o755)
            ip_calls = root / "ip.log"
            fake_ip = root / "ip"
            fake_ip.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$IP_LOG\"\n", encoding="utf-8")
            fake_ip.chmod(0o755)
            env = dict(os.environ, ASAKO_PROXY_STATE_DIR=str(state_dir), ASAKO_SYSTEMCTL=str(fake_systemctl),
                       ASAKO_IP=str(fake_ip), CALL_LOG=str(calls), IP_LOG=str(ip_calls),
                       ASAKO_CLASH_API="http://127.0.0.1:1", ASAKO_CLASH_ATTEMPTS="1",
                       ASAKO_CLASH_RETRY_DELAY="0")
            subprocess.run(["python3", str(state_path), "guard"], env=env, check=True)
            ip_calls.unlink()
            result = subprocess.run(["python3", str(state_path), "sachi"], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((state_dir / "state").read_text().strip(), "hk")
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-hk-tun.service", "start sing-box-tun.service"])
            self.assertFalse(ip_calls.exists())

    def test_boot_guard_installs_both_family_blackholes_and_precedes_tailscaled(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state_dir = root / "state"
            state_dir.mkdir()
            (state_dir / "state").write_text("hk\n", encoding="ascii")
            ip_calls = root / "ip.log"
            fake_ip = root / "ip"
            fake_ip.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$IP_LOG\"\n", encoding="utf-8")
            fake_ip.chmod(0o755)
            env = dict(os.environ, ASAKO_PROXY_STATE_DIR=str(state_dir), ASAKO_IP=str(fake_ip), IP_LOG=str(ip_calls))
            subprocess.run(["python3", str(state_path), "guard"], env=env, check=True)
            routes = ip_calls.read_text()
            self.assertIn("-4 route replace blackhole 100.64.0.0/10 table 110", routes)
            self.assertIn("-6 route replace blackhole fd7a:115c:a1e0::/48 table 110", routes)
            self.assertIn("-4 rule add priority 1001 iif lo to 100.64.0.0/10 lookup 110", routes)
            self.assertIn("-6 rule add priority 1001 iif lo to fd7a:115c:a1e0::/48 lookup 110", routes)
            self.assertNotIn("sing-box-hk-tun", routes)

        options = Path(__file__).with_name("proxy-options.nix").read_text(encoding="utf-8")
        guard = options.split("systemd.services.asako-proxy-hk-guard = {", 1)[1].split("};", 1)[0]
        self.assertIn('wantedBy = [ "tailscaled.service" ]', guard)
        self.assertIn('requiredBy = [ "tailscaled.service" ]', guard)
        self.assertIn('before = [ "tailscaled.service" ]', guard)
        restore = options.split("systemd.services.asako-proxy-restore = {", 1)[1].split("};", 1)[0]
        self.assertIn('"asako-proxy-hk-guard.service"', restore)


if __name__ == "__main__":
    unittest.main()
