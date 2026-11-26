import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("asako_hk", Path(__file__).with_name("asako-hk.py"))
asako_hk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asako_hk)


class AsakoHKConfigTests(unittest.TestCase):
    def test_runtime_profile_renders_hk_routes_without_store_secrets(self):
        profile = {
            "host": "203.0.113.2", "port": 443,
            "direct_uuid": "11111111-1111-4111-8111-111111111111",
            "us_uuid": "22222222-2222-4222-8222-222222222222",
            "public_key": "key-from-runtime", "short_id": "abcd1234",
            "us_domains": ["example.com"],
        }
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "asako-hk.json"
            source.write_text(json.dumps(profile), encoding="utf-8")
            android_profiles = Path(__file__).parents[4] / "makina" / "android-profiles.py"
            config = asako_hk.render(source, android_profiles)
        self.assertEqual(config["inbounds"][0]["interface_name"], "singtun-hk0")
        self.assertEqual(config["inbounds"][0]["address"], ["198.18.0.1/30"])
        self.assertEqual(config["outbounds"][0]["tag"], "hk-direct")
        self.assertEqual(config["outbounds"][1]["tag"], "hk-us")
        rules = config["route"]["rules"]
        self.assertEqual(rules[0]["action"], "sniff")
        self.assertEqual(rules[2]["domain_suffix"], ["mado.moe"])
        self.assertEqual(rules[3]["ip_cidr"], ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        self.assertEqual(rules[6]["domain"], ["example.com"])
        self.assertIn("203.0.113.2/32", config["inbounds"][0]["route_exclude_address"])
        self.assertEqual(config["dns"]["strategy"], "ipv4_only")
        self.assertEqual(config["dns"]["rules"][1]["server"], "local-dns")
        self.assertIn("key-from-runtime", json.dumps(config))
        self.assertEqual(config["outbounds"][0]["tls"]["server_name"], "www.apple.com")
        self.assertEqual(config["outbounds"][1]["tls"]["server_name"], "www.apple.com")

    def test_hk_render_respects_primary_targets_env_var(self):
        profile = {
            "host": "203.0.113.2", "port": 443,
            "direct_uuid": "11111111-1111-4111-8111-111111111111",
            "us_uuid": "22222222-2222-4222-8222-222222222222",
            "public_key": "key-from-runtime", "short_id": "abcd1234",
        }
        with tempfile.TemporaryDirectory() as temp:
            override = Path(temp) / "primary.json"
            override.write_text(json.dumps({"amane": "a", "sachi": "s", "michiru": "env.hkust.test"}))
            source = Path(temp) / "asako-hk.json"
            source.write_text(json.dumps(profile), encoding="utf-8")
            android_profiles = Path(__file__).parents[4] / "makina" / "android-profiles.py"
            with patch.dict(os.environ, {"REALITY_PRIMARY_TARGETS_FILE": str(override)}):
                config = asako_hk.render(source, android_profiles)
        self.assertEqual(config["outbounds"][0]["tls"]["server_name"], "env.hkust.test")


if __name__ == "__main__":
    unittest.main()
