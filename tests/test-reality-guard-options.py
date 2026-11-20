#!/usr/bin/env python3
"""Regression tests for my.services.realityGuard option and assertion validation (AC3)."""

import json
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def eval_guard(module_body: str) -> tuple[bool, list[str], str]:
    """Evaluate amane.extendModules with an override module; return (ok, failed_assertions, stderr)."""
    apply_expr = (
        "amane: let "
        f"ext = amane.extendModules {{ modules = [ ({{ lib, ... }}: {{ my.services.realityGuard = {{ {module_body} }}; }}) ]; }}; "
        "rg = ext.config.my.services.realityGuard; "
        "failed = builtins.map (a: a.message) (builtins.filter (a: !a.assertion) ext.config.assertions); "
        "in { strict = rg.strictDomains; relaxed = rg.relaxedDomains; ports = rg.inboundPorts; inherit failed; }"
    )
    proc = subprocess.run(
        [
            "nix",
            "eval",
            "--no-write-lock-file",
            "--json",
            ".#nixosConfigurations.amane",
            "--apply",
            apply_expr,
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return False, [], proc.stderr
    data = json.loads(proc.stdout)
    failed = data.get("failed", [])
    return len(failed) == 0, failed, proc.stderr


class TestRealityGuardOptions(unittest.TestCase):
    def test_valid_config_evaluates(self):
        ok, failed, stderr = eval_guard(
            'strictDomains = lib.mkForce [ "decoy.test" ]; '
            'relaxedDomains = lib.mkForce [ "sub-1.relaxed.example" ];'
        )
        self.assertTrue(ok, f"expected valid config to pass, failed={failed}, stderr={stderr}")

    def test_malformed_hostname_space_rejected(self):
        ok, failed, stderr = eval_guard('strictDomains = lib.mkForce [ "not a hostname" ];')
        self.assertFalse(ok, "expected 'not a hostname' in strictDomains to be rejected")

    def test_malformed_hostname_leading_hyphen_rejected(self):
        ok, failed, stderr = eval_guard('relaxedDomains = lib.mkForce [ "-bad.example" ];')
        self.assertFalse(ok, "expected '-bad.example' in relaxedDomains to be rejected")

    def test_empty_targets_and_ports_rejected(self):
        ok, failed, stderr = eval_guard(
            "strictDomains = lib.mkForce []; relaxedDomains = lib.mkForce []; inboundPorts = lib.mkForce [];"
        )
        self.assertFalse(ok, "expected empty domains + ports to be rejected")

    def test_out_of_range_port_rejected(self):
        ok, failed, stderr = eval_guard("inboundPorts = lib.mkForce [ 65536 ];")
        self.assertFalse(ok, "expected port 65536 to be rejected")

    def test_inverted_quota_rejected(self):
        ok, failed, stderr = eval_guard(
            "strict.perConnAllowance = lib.mkForce 2048; strict.perConnQuota = lib.mkForce 1024;"
        )
        self.assertFalse(ok, "expected perConnAllowance > perConnQuota to be rejected")


if __name__ == "__main__":
    unittest.main()
