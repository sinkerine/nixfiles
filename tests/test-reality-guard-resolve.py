#!/usr/bin/env python3
"""Unit tests for hosts/modules/services/networking/reality-guard-resolve.py."""

import importlib.util
import io
import json
import os
import socket
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parent.parent
RESOLVE_SCRIPT = (
    REPO_ROOT / "hosts" / "modules" / "services" / "networking" / "reality-guard-resolve.py"
)


def load_module():
    if not RESOLVE_SCRIPT.exists():
        raise FileNotFoundError(f"Resolver script not found: {RESOLVE_SCRIPT}")
    spec = importlib.util.spec_from_file_location("reality_guard_resolve", RESOLVE_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestRealityGuardResolve(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.cache_path = Path(self.tmpdir.name) / "cache.json"
        self.config_path = Path(self.tmpdir.name) / "config.json"

    def write_config(self, strict=None, relaxed=None, retention=1800):
        cfg = {
            "strictDomains": strict if strict is not None else ["decoy.test"],
            "relaxedDomains": relaxed if relaxed is not None else ["relaxed.test"],
            "ipRetentionSeconds": retention,
            "cacheFile": str(self.cache_path),
        }
        self.config_path.write_text(json.dumps(cfg))
        return cfg

    @staticmethod
    def fake_addrinfo(ips):
        results = []
        for ip in ips:
            if ":" in ip:
                results.append((socket.AF_INET6, socket.SOCK_STREAM, 6, "", (ip, 443, 0, 0)))
            else:
                results.append((socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, 443)))
        return results

    def test_resolve_populates_strict_and_relaxed_v4_v6(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=["relaxed.test"])
        nft_inputs = []

        def fake_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
            if host == "decoy.test":
                return self.fake_addrinfo(["192.0.2.10", "2001:db8::10"])
            if host == "relaxed.test":
                return self.fake_addrinfo(["198.51.100.20"])
            raise socket.gaierror("unknown host")

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append((cmd, input))
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("socket.getaddrinfo", side_effect=fake_getaddrinfo),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=1000.0),
        ):
            rc = mod.main([str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertEqual(len(nft_inputs), 1)
        cmd, script = nft_inputs[0]
        self.assertEqual(cmd[-2:], ["-f", "-"])
        self.assertIn("flush set inet reality_guard decoy_strict_v4", script)
        self.assertIn("add element inet reality_guard decoy_strict_v4 { 192.0.2.10 }", script)
        self.assertIn("add element inet reality_guard decoy_strict_v6 { 2001:db8::10 }", script)
        self.assertIn("add element inet reality_guard decoy_relaxed_v4 { 198.51.100.20 }", script)
        self.assertIn("flush set inet reality_guard decoy_relaxed_v6", script)
        self.assertNotIn("add element inet reality_guard decoy_relaxed_v6", script)

        cache = json.loads(self.cache_path.read_text())
        self.assertIn("192.0.2.10", cache["decoy.test"]["v4"])
        self.assertIn("2001:db8::10", cache["decoy.test"]["v6"])

    def test_empty_sets_omit_add_element(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])
        nft_inputs = []

        def fake_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
            return self.fake_addrinfo(["192.0.2.10"])

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("socket.getaddrinfo", side_effect=fake_getaddrinfo),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=1000.0),
        ):
            rc = mod.main([str(self.config_path)])

        self.assertEqual(rc, 0)
        script = nft_inputs[0]
        self.assertNotIn("{ }", script)
        self.assertIn("add element inet reality_guard decoy_strict_v4 { 192.0.2.10 }", script)
        self.assertNotIn("add element inet reality_guard decoy_strict_v6", script)
        self.assertNotIn("add element inet reality_guard decoy_relaxed_v4", script)
        self.assertNotIn("add element inet reality_guard decoy_relaxed_v6", script)

    def test_retention_keeps_rotating_ips_and_expires_old_ips(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[], retention=1800)
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("socket.getaddrinfo", return_value=self.fake_addrinfo(["192.0.2.1"])),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=1000.0),
        ):
            self.assertEqual(mod.main([str(self.config_path)]), 0)

        with (
            mock.patch("socket.getaddrinfo", return_value=self.fake_addrinfo(["192.0.2.2"])),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=1500.0),
        ):
            self.assertEqual(mod.main([str(self.config_path)]), 0)

        self.assertIn("192.0.2.1", nft_inputs[-1])
        self.assertIn("192.0.2.2", nft_inputs[-1])

        with (
            mock.patch("socket.getaddrinfo", return_value=self.fake_addrinfo(["192.0.2.2"])),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=3000.0),
        ):
            self.assertEqual(mod.main([str(self.config_path)]), 0)

        self.assertNotIn("192.0.2.1", nft_inputs[-1])
        self.assertIn("192.0.2.2", nft_inputs[-1])

    def test_dns_failure_preserves_cached_ips_and_exits_zero(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[], retention=1800)
        self.cache_path.write_text(
            json.dumps(
                {
                    "decoy.test": {
                        "v4": {"192.0.2.99": 100.0},
                        "v6": {},
                    }
                }
            )
        )
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        stderr_buf = io.StringIO()
        with (
            mock.patch("socket.getaddrinfo", side_effect=socket.gaierror("DNS timeout")),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=5000.0),
            redirect_stderr(stderr_buf),
        ):
            rc = mod.main([str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertIn("192.0.2.99", nft_inputs[0])
        self.assertIn("decoy.test", stderr_buf.getvalue())

    def test_apply_cache_only_restores_without_dns(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=["relaxed.test"])
        self.cache_path.write_text(
            json.dumps(
                {
                    "decoy.test": {
                        "v4": {"192.0.2.10": 100.0},
                        "v6": {"2001:db8::10": 100.0},
                    },
                    "relaxed.test": {
                        "v4": {"198.51.100.20": 100.0},
                        "v6": {},
                    },
                }
            )
        )
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("socket.getaddrinfo", side_effect=AssertionError("must not call DNS")),
            mock.patch("subprocess.run", side_effect=fake_run),
        ):
            rc = mod.main(["--apply-cache-only", str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertIn("add element inet reality_guard decoy_strict_v4 { 192.0.2.10 }", nft_inputs[0])
        self.assertIn("add element inet reality_guard decoy_strict_v6 { 2001:db8::10 }", nft_inputs[0])
        self.assertIn("add element inet reality_guard decoy_relaxed_v4 { 198.51.100.20 }", nft_inputs[0])

    def test_apply_cache_only_missing_cache_noops_cleanly(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])

        with mock.patch("subprocess.run") as mock_run:
            rc = mod.main(["--apply-cache-only", str(self.config_path)])

        self.assertEqual(rc, 0)
        mock_run.assert_not_called()

    def test_nft_failure_exits_nonzero(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="nft syntax error")

        stderr_buf = io.StringIO()
        with (
            mock.patch("socket.getaddrinfo", return_value=self.fake_addrinfo(["192.0.2.10"])),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=1000.0),
            redirect_stderr(stderr_buf),
        ):
            rc = mod.main([str(self.config_path)])

        self.assertNotEqual(rc, 0)
        self.assertIn("nft", stderr_buf.getvalue().lower())

    def test_render_ruleset_single_nft_transaction_with_cache(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=["relaxed.test"])
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard\ndelete table inet reality_guard\ntable inet reality_guard {}\n")
        self.cache_path.write_text(
            json.dumps({
                "decoy.test": {"v4": {"192.0.2.10": 100.0}, "v6": {"2001:db8::10": 100.0}},
                "relaxed.test": {"v4": {"198.51.100.20": 100.0}, "v6": {}},
            })
        )
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append((cmd, input))
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("socket.getaddrinfo", side_effect=AssertionError("must not call DNS")),
            mock.patch("subprocess.run", side_effect=fake_run),
        ):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertEqual(len(nft_inputs), 1)
        cmd, script = nft_inputs[0]
        self.assertEqual(cmd[-2:], ["-f", "-"])
        self.assertIn("delete table inet reality_guard", script)
        self.assertIn("add element inet reality_guard decoy_strict_v4 { 192.0.2.10 }", script)
        self.assertIn("add element inet reality_guard decoy_strict_v6 { 2001:db8::10 }", script)
        self.assertIn("add element inet reality_guard decoy_relaxed_v4 { 198.51.100.20 }", script)

    def test_render_ruleset_no_cache_applies_static_rules_only(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard {}\n")
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with mock.patch("subprocess.run", side_effect=fake_run):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertEqual(len(nft_inputs), 1)
        self.assertIn("table inet reality_guard {}", nft_inputs[0])
        self.assertNotIn("add element", nft_inputs[0])

    def test_render_ruleset_nft_failure_exits_nonzero(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard {}\n")

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="nft failed")

        stderr_buf = io.StringIO()
        with mock.patch("subprocess.run", side_effect=fake_run), redirect_stderr(stderr_buf):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertNotEqual(rc, 0)
        self.assertIn("nft", stderr_buf.getvalue().lower())

    def test_lock_held_around_cache_write_and_nft_apply(self):
        mod = load_module()
        lock_path = Path(self.tmpdir.name) / "guard.lock"
        cfg = self.write_config(strict=["decoy.test"], relaxed=[])
        cfg["lockFile"] = str(lock_path)
        self.config_path.write_text(json.dumps(cfg))

        events = []
        import fcntl
        orig_flock = fcntl.flock

        def spy_flock(fd, op):
            if op == fcntl.LOCK_EX:
                events.append("lock")
            elif op == fcntl.LOCK_UN:
                events.append("unlock")
            return orig_flock(fd, op)

        def fake_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
            events.append("dns")
            return self.fake_addrinfo(["192.0.2.10"])

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            events.append("nft")
            self.assertTrue(self.cache_path.exists())
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("fcntl.flock", side_effect=spy_flock),
            mock.patch("socket.getaddrinfo", side_effect=fake_getaddrinfo),
            mock.patch("subprocess.run", side_effect=fake_run),
            mock.patch("time.time", return_value=1000.0),
        ):
            rc = mod.main([str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertEqual(events, ["dns", "lock", "nft", "unlock"])

    def test_render_ruleset_rereads_latest_cache_under_lock(self):
        mod = load_module()
        lock_path = Path(self.tmpdir.name) / "guard.lock"
        cfg = self.write_config(strict=["decoy.test"], relaxed=[])
        cfg["lockFile"] = str(lock_path)
        self.config_path.write_text(json.dumps(cfg))
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard {}\n")
        self.cache_path.write_text(json.dumps({"decoy.test": {"v4": {"192.0.2.1": 100.0}, "v6": {}}}))

        import fcntl
        orig_flock = fcntl.flock
        nft_inputs = []

        def simulating_flock(fd, op):
            res = orig_flock(fd, op)
            if op == fcntl.LOCK_EX:
                # Simulate a live resolve that finished committing newer IP before reload got the lock
                self.cache_path.write_text(
                    json.dumps({"decoy.test": {"v4": {"192.0.2.2": 200.0}, "v6": {}}})
                )
            return res

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        with (
            mock.patch("fcntl.flock", side_effect=simulating_flock),
            mock.patch("subprocess.run", side_effect=fake_run),
        ):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertIn("192.0.2.2", nft_inputs[0])
        self.assertNotIn("192.0.2.1", nft_inputs[0])
        # Cache must still hold the newer IP
        self.assertIn("192.0.2.2", json.loads(self.cache_path.read_text())["decoy.test"]["v4"])

    def test_scoped_ipv6_in_cache_dropped_no_percent_in_batch(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard {}\n")
        self.cache_path.write_text(
            json.dumps({
                "decoy.test": {
                    "v4": {},
                    "v6": {
                        "fe80::1%eth0": 100.0,
                        "2001:db8::1%evil;": 100.0,
                        "2001:db8::2": 100.0,
                    },
                }
            })
        )
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        stderr_buf = io.StringIO()
        with mock.patch("subprocess.run", side_effect=fake_run), redirect_stderr(stderr_buf):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertNotIn("%", nft_inputs[0])
        self.assertIn("2001:db8::2", nft_inputs[0])

    def test_malformed_cache_records_discarded_valid_kept(self):
        mod = load_module()
        self.write_config(strict=["good.test", "null.test", "badfam.test"], relaxed=[])
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard {}\n")
        self.cache_path.write_text(
            json.dumps({
                "good.test": {"v4": {"192.0.2.10": 100.0}, "v6": {}},
                "null.test": None,
                "badfam.test": {"v4": ["192.0.2.20"], "v6": {}},
            })
        )
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        stderr_buf = io.StringIO()
        with mock.patch("subprocess.run", side_effect=fake_run), redirect_stderr(stderr_buf):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertIn("192.0.2.10", nft_inputs[0])
        self.assertNotIn("192.0.2.20", nft_inputs[0])
        self.assertIn("warning", stderr_buf.getvalue().lower())

    def test_unparsable_cache_json_falls_back_to_static_rules(self):
        mod = load_module()
        self.write_config(strict=["decoy.test"], relaxed=[])
        rules_path = Path(self.tmpdir.name) / "rules.nft"
        rules_path.write_text("table inet reality_guard {}\n")
        self.cache_path.write_text("{not valid json")
        nft_inputs = []

        def fake_run(cmd, input=None, text=None, capture_output=None, check=False):
            nft_inputs.append(input)
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

        stderr_buf = io.StringIO()
        with mock.patch("subprocess.run", side_effect=fake_run), redirect_stderr(stderr_buf):
            rc = mod.main(["--render-ruleset", str(rules_path), str(self.config_path)])

        self.assertEqual(rc, 0)
        self.assertIn("table inet reality_guard {}", nft_inputs[0])
        self.assertNotIn("add element", nft_inputs[0])
        self.assertIn("warning", stderr_buf.getvalue().lower())


if __name__ == "__main__":
    unittest.main()
