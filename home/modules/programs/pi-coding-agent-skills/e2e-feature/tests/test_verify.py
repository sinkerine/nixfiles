import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "scripts" / "verify.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("e2e_verify", SCRIPT)
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "repo"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Test")
        (self.root / "source").write_text("original")
        (self.root / ".gitignore").write_text("generated\noutput\n.pi/\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.run_dir = self.root / ".git" / "e2e-feature" / "test"
        self.recipe = {"version": 1, "env_keys": ["E2E_TEST_ENV"], "environment_inputs": ["generated"], "checks": [{"id": "units", "command": "echo checked", "timeout_seconds": 5}]}
        self.check = self.recipe["checks"][0]

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL)

    def run_check(self):
        return verify.run_check(self.root, self.run_dir, self.recipe, self.check)

    def test_reuses_passing_host_evidence_and_invalidates_source(self):
        self.assertFalse(self.run_check()["reused"])
        self.assertTrue(self.run_check()["reused"])
        (self.root / "source").write_text("edited")
        self.assertFalse(self.run_check()["reused"])
        (self.root / "untracked").write_text("new input")
        self.assertFalse(self.run_check()["reused"])

    def test_environment_and_ignored_dependency_invalidate(self):
        self.run_check()
        with patch.dict(os.environ, {"E2E_TEST_ENV": "changed"}):
            self.assertFalse(self.run_check()["reused"])
        (self.root / "generated").write_text("AAR identity")
        self.assertFalse(self.run_check()["reused"])
        (self.root / "generated").write_text("new AAR identity")
        self.assertFalse(self.run_check()["reused"])

    def test_changed_command_does_not_reuse(self):
        self.run_check()
        self.check["command"] = "echo different"
        self.assertFalse(self.run_check()["reused"])

    def test_failure_is_never_cached(self):
        self.check["command"] = "exit 1"
        self.assertEqual(self.run_check()["status"], "failed")
        self.assertFalse(self.run_check()["reused"])

    def test_edit_during_check_is_stale(self):
        self.check["command"] = "echo mutated > source"
        self.assertEqual(self.run_check()["status"], "stale")

    def test_artifact_and_log_integrity(self):
        self.check["command"] = "echo coverage > output"
        self.check["artifacts"] = ["output"]
        first = self.run_check()
        self.assertTrue(self.run_check()["reused"])
        (self.root / "output").unlink()
        self.assertFalse(self.run_check()["reused"])
        Path(first["log"]).unlink()
        receipt = json.loads(Path(first["receipt"]).read_text())
        Path(receipt["log"]).write_text("tampered")
        self.assertFalse(self.run_check()["reused"])

    def test_missing_required_artifact_fails(self):
        self.check["artifacts"] = ["output"]
        self.assertEqual(self.run_check()["status"], "missing-artifact")

    def test_explicit_scope_preserves_evidence_across_unrelated_edits(self):
        self.check["inputs"] = ["source"]
        self.run_check()
        (self.root / "unrelated").write_text("other task")
        self.assertTrue(self.run_check()["reused"])
        (self.root / "source").unlink()
        self.assertFalse(self.run_check()["reused"])

    def test_runtime_metadata_does_not_invalidate(self):
        self.run_check()
        (self.root / ".pi" / "goals").mkdir(parents=True)
        (self.root / ".pi" / "goals" / "active.md").write_text("updated")
        self.assertTrue(self.run_check()["reused"])

    def test_command_cannot_leave_background_descendants(self):
        self.check["command"] = "sleep 10 &"
        self.assertEqual(self.run_check()["status"], "failed")

    def test_timeout_kills_command_group(self):
        self.check.update(command="sleep 10; echo leaked > output", timeout_seconds=1)
        result = self.run_check()
        self.assertEqual(result["status"], "timed-out")
        self.assertFalse((self.root / "output").exists())

    def test_init_preserves_settings_and_handoff_copies_report(self):
        (self.root / ".gitignore").write_text("generated\noutput\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "runtime metadata is not preignored")
        settings = self.root / ".pi" / "pi-goal-x-settings.json"
        settings.parent.mkdir()
        settings.write_text(json.dumps({"auditorEnabled": False}))
        subprocess.check_output(["python3", str(SCRIPT), "init", "--feature", "test"], cwd=self.root)
        self.assertEqual(json.loads(settings.read_text()), {"auditorEnabled": False, "strictExecutionContract": True, "idleContinuationBackoff": True})
        self.assertEqual(self.git("status", "--porcelain"), b"", "initialization must not leave generated metadata in the feature diff")
        report = Path(self.temp.name) / "producer-report.md"
        report.write_text("proof of compatibility")
        producer = Path(self.temp.name) / "producer"
        producer.mkdir()
        def producer_git(*args):
            return subprocess.check_output(["git", "-C", str(producer), *args], stderr=subprocess.DEVNULL)
        producer_git("init", "-q")
        producer_git("config", "user.email", "test@example.invalid")
        producer_git("config", "user.name", "Test")
        (producer / "api").write_text("old-plus-new APIs")
        producer_git("add", ".")
        producer_git("commit", "-qm", "compatible dependency")
        sha = producer_git("rev-parse", "HEAD").decode().strip()
        with self.assertRaises(subprocess.CalledProcessError):
            self.git("cat-file", "-e", sha)
        result = json.loads(subprocess.check_output(["python3", str(SCRIPT), "handoff", "--feature", "test", "--producer-repo", str(producer), "--sha", sha, "--report", str(report)], cwd=self.root))
        report.unlink()
        shutil.rmtree(producer)
        self.assertEqual(result["sha"], sha)
        self.assertEqual(Path(result["report"]).read_text(), "proof of compatibility")

    def test_unknown_check_and_invalid_recipe_do_not_execute(self):
        recipe = self.root / ".git" / "recipe.json"
        recipe.write_text(json.dumps(self.recipe))
        result = subprocess.run(["python3", str(SCRIPT), "verify", "--feature", "test", "--recipe", str(recipe), "--check", "unknown"], cwd=self.root, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.run_dir / "verification").exists())
        self.check["inputs"] = ["../outside"]
        recipe.write_text(json.dumps(self.recipe))
        with self.assertRaises(ValueError):
            verify.load_recipe(recipe)


if __name__ == "__main__":
    unittest.main()
