import importlib.util
import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("android_profiles", Path(__file__).with_name("android-profiles.py"))
android_profiles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(android_profiles)
state_path = Path(__file__).with_name("proxy-state.py")


class AndroidProfileTests(unittest.TestCase):
    def test_json_exports_preserve_routing_modes(self):
        uuid = "00000000-0000-4000-8000-000000000000"
        with tempfile.TemporaryDirectory() as temp:
            secret_path = Path(temp) / "uuid"
            secret_path.write_text(uuid, encoding="ascii")
            output_dir = Path(temp) / "profiles"
            paths = [Path(path) for path in android_profiles.generate(secret_path, output_dir)]
            expected = {
                f"{server}-{mode}" + ("-tailscale" if tailscale else "") + ".json"
                for server in android_profiles.SERVERS
                for mode in ("normal", "paypal")
                for tailscale in (False, True)
            }
            self.assertEqual({path.name for path in paths}, expected)
            for path in paths:
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

            for server_name in android_profiles.SERVERS:
                for mode in ("normal", "paypal"):
                    for tailscale in (False, True):
                        name = f"{server_name}-{mode}" + ("-tailscale" if tailscale else "")
                        config = json.loads((output_dir / f"{name}.json").read_text())
                        self.assertEqual(config["route"]["final"], "proxy")
                        self.assertNotIn("route_exclude_address", config["inbounds"][0])
                        self.assertIn(
                            {"ip_cidr": android_profiles.LAN_DIRECT_CIDRS, "action": "route", "outbound": "direct"},
                            config["route"]["rules"],
                        )
                        if tailscale:
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
                        else:
                            self.assertNotIn("endpoints", config)
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

            keys = {"amane-normal-tailscale": "one-time-test-key"}
            android_profiles.generate(secret_path, output_dir, keys)
            authorized = json.loads((output_dir / "amane-normal-tailscale.json").read_text())
            self.assertEqual(authorized["endpoints"][0]["auth_key"], "one-time-test-key")
            other = json.loads((output_dir / "sachi-normal-tailscale.json").read_text())
            self.assertNotIn("auth_key", other["endpoints"][0])


class ProxyStateTests(unittest.TestCase):
    def test_toggle_persists_and_boot_restore_honors_choice(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state_dir = root / "state"
            calls = root / "systemctl.log"
            fake_systemctl = root / "systemctl"
            fake_systemctl.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CALL_LOG\"\n", encoding="utf-8")
            fake_systemctl.chmod(0o755)
            env = dict(os.environ, ASAKO_PROXY_STATE_DIR=str(state_dir), ASAKO_SYSTEMCTL=str(fake_systemctl), CALL_LOG=str(calls))

            def run(*args):
                subprocess.run(["python3", str(state_path), *args], env=env, check=True)

            run("enable")
            self.assertEqual((state_dir / "state").read_text().strip(), "on")
            self.assertEqual(calls.read_text().splitlines(), ["start sing-box-tun.service"])
            calls.unlink()
            run("restore", "off")
            self.assertEqual(calls.read_text().splitlines(), ["start sing-box-tun.service"])

            calls.unlink()
            run("disable")
            self.assertEqual((state_dir / "state").read_text().strip(), "off")
            self.assertEqual(calls.read_text().splitlines(), ["stop sing-box-tun.service"])
            calls.unlink()
            run("restore", "on")
            self.assertFalse(calls.exists())


if __name__ == "__main__":
    unittest.main()
