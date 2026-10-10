import json
import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).with_name("ipv6-config.py")
class GatewayIPv6ConfigTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.base = self.root / "base.json"
        self.output = self.root / "dynamic.json"
        self.base.write_text(json.dumps({"http": {"middlewares": {
            "lan-only": {"ipAllowList": {"sourceRange": ["127.0.0.1/32", "100.64.0.0/10", "fd7a:115c:a1e0::/48"]}},
            "wan": {"ipAllowList": {"sourceRange": ["127.0.0.1/32", "100.64.0.0/10", "fd7a:115c:a1e0::/48"]}},
        }}}))

    def tearDown(self):
        self.tempdir.cleanup()

    def run_generator(self, interface="vmbr0", result=None, error=None):
        argv = ["ipv6-config.py", str(self.base), str(self.output), interface, "/fake/ip"]
        with patch.object(sys, "argv", argv):
            if error:
                call = patch.object(subprocess, "check_output", side_effect=error)
            else:
                call = patch.object(subprocess, "check_output", return_value=json.dumps(result or []).encode())
            with call:
                runpy.run_path(str(SCRIPT))

    def networks(self, name="lan-only"):
        config = json.loads(self.output.read_text())
        return config["http"]["middlewares"][name]["ipAllowList"]["sourceRange"]

    def test_no_interface_keeps_base_allowlists(self):
        self.run_generator("-")
        self.assertEqual(self.networks(), ["127.0.0.1/32", "100.64.0.0/10", "fd7a:115c:a1e0::/48"])

    def test_absent_interface_keeps_base_and_removes_old_prefix(self):
        previous = json.loads(self.base.read_text())
        for name in ("lan-only", "wan"):
            previous["http"]["middlewares"][name]["ipAllowList"]["sourceRange"].append("2600:1700:38d0:3bf0::/64")
        self.output.write_text(json.dumps(previous))
        self.run_generator(error=subprocess.CalledProcessError(1, "ip"))
        self.assertNotIn("2600:1700:38d0:3bf0::/64", self.networks())
        self.assertIn("100.64.0.0/10", self.networks())

    def test_changed_prefix_replaces_previous_prefix(self):
        self.output.write_text('{"old":"prefix"}')
        self.run_generator(result=[{"addr_info": [{"local": "2001:db8:1::2", "prefixlen": 64, "scope": "global"}]}])
        # Documentation ranges are not globally routable in ipaddress; use a
        # representative global address to exercise the learned prefix path.
        self.assertNotIn("2001:db8:1::/64", self.networks())
        self.run_generator(result=[{"addr_info": [{"local": "2600:1700:1::2", "prefixlen": 64, "scope": "global"}]}])
        self.assertIn("2600:1700:1::/64", self.networks())
        self.assertNotIn("2600:1700:38d0:3bf0::/64", self.networks())

    def test_invalid_and_deprecated_addresses_are_ignored(self):
        infos = [
            {"local": "2600:1700:1::2", "prefixlen": 64, "flags": ["tentative"]},
            {"local": "2600:1700:2::2", "prefixlen": 64, "flags": ["dadfailed"]},
            {"local": "2600:1700:3::2", "prefixlen": 64, "flags": ["deprecated"]},
            {"local": "not-an-address", "prefixlen": 64},
            {"local": "fe80::1", "prefixlen": 64},
            {"local": "fd00::1", "prefixlen": 64},
        ]
        self.run_generator(result=[{"addr_info": infos}])
        self.assertEqual(self.networks(), ["127.0.0.1/32", "100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        self.assertEqual(self.networks("wan"), self.networks())


if __name__ == "__main__":
    unittest.main()
