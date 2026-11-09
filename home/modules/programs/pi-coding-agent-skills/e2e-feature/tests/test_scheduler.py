import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import threading
import time
import unittest

import test_verify
from scheduler import run_checks, select_checks

verify = test_verify.verify


class SchedulingTests(unittest.TestCase):
    setUp = test_verify.VerificationTests.setUp
    git = test_verify.VerificationTests.git

    def make_recipe(self, checks, resources=None, parallel=2):
        value = {"version": 1, "max_parallel": parallel, "resources": resources or {"a": {}, "b": {}}, "checks": checks}
        path = self.root / ".git" / "recipe.json"
        path.write_text(json.dumps(value))
        return verify.load_recipe(path)

    def run_recipe(self, recipe, selected=(), stop=None, execute=None):
        recipe["_evidence_dir"] = str(self.run_dir / "verification")
        checks = select_checks(recipe, selected)
        return run_checks(self.root, self.root / ".git", self.root / ".git", self.run_dir, recipe, checks,
                          execute or (lambda check, cancellation: verify.run_check(self.root, self.run_dir, recipe, check, stop=cancellation)), stop)

    def python(self, code):
        return shlex.quote(sys.executable) + " -c " + shlex.quote(code)

    def test_independent_real_commands_overlap_and_dependencies_are_included(self):
        barrier = self.root / ".git" / "barrier"
        barrier.mkdir()
        def command(own, other):
            return self.python(f"from pathlib import Path; import time; p=Path({str(barrier)!r}); (p/{own!r}).touch(); end=time.monotonic()+2\nwhile not (p/{other!r}).exists():\n assert time.monotonic()<end, 'independent check did not overlap'; time.sleep(.01)")
        recipe = self.make_recipe([
            {"id": "a", "phase": "smoke", "resources": ["a"], "command": command("a", "b")},
            {"id": "b", "phase": "smoke", "resources": ["b"], "command": command("b", "a")},
            {"id": "full", "needs": ["a", "b"], "command": "echo full"},
        ])
        results = self.run_recipe(recipe, ["full"])
        self.assertEqual([r["status"] for r in results], ["passed"] * 3)
        self.assertGreaterEqual(results[2]["ready_at"], max(r["settled_at"] for r in results[:2]))

    def test_shared_resource_and_unknown_commands_stay_serial(self):
        for first, second in [(["a"], ["a"]), (None, ["b"])]:
            with self.subTest(first=first, second=second):
                checks = [{"id": "one", "command": "true"}, {"id": "two", "command": "true"}]
                if first:
                    checks[0]["resources"] = first
                checks[1]["resources"] = second
                recipe = self.make_recipe(checks)
                active, maximum = 0, 0
                mutex = threading.Lock()
                def execute(check, stop):
                    nonlocal active, maximum
                    with mutex:
                        active += 1
                        maximum = max(active, maximum)
                    stop.wait(.08)
                    with mutex:
                        active -= 1
                    return {"id": check["id"], "status": "passed"}
                results = self.run_recipe(recipe, execute=execute)
                self.assertEqual(maximum, 1)
                self.assertTrue(any(r["lock_wait_seconds"] > 0 for r in results))

    def test_parallel_limit_and_cross_invocation_repository_lock(self):
        recipe = self.make_recipe([{"id": name, "command": "true", "resources": [name]} for name in ["a", "b", "c"]],
                             resources={name: {} for name in ["a", "b", "c"]})
        active, maximum = 0, 0
        mutex = threading.Lock()
        def execute(check, stop):
            nonlocal active, maximum
            with mutex:
                active += 1
                maximum = max(maximum, active)
            stop.wait(.08)
            with mutex:
                active -= 1
            return {"id": check["id"], "status": "passed"}
        self.run_recipe(recipe, execute=execute)
        self.assertEqual(maximum, 2)
        maximum = 0
        recipe = self.make_recipe([{"id": "only", "command": "true", "resources": ["shared"]}],
                             resources={"shared": {"scope": "repository"}})
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            futures = []
            for index in range(2):
                git_dir = self.root / ".git" / f"worktree-{index}"
                futures.append(pool.submit(run_checks, self.root, git_dir, self.root / ".git", git_dir / "run", recipe, recipe["checks"], execute))
            for future in futures:
                self.assertEqual(future.result()[0]["status"], "passed")
        self.assertEqual(maximum, 1)

    def test_failure_blocks_dependents_but_preserves_independent_checks(self):
        recipe = self.make_recipe([
            {"id": "a", "resources": ["a"], "command": "exit 3"},
            {"id": "dependent", "needs": ["a"], "command": "touch should-not-exist"},
            {"id": "b", "resources": ["b"], "command": "echo independent"},
        ])
        results = {r["id"]: r for r in self.run_recipe(recipe)}
        self.assertEqual(results["a"]["status"], "failed")
        self.assertEqual(results["dependent"]["status"], "blocked")
        self.assertEqual(results["b"]["status"], "passed")
        self.assertFalse((self.root / "should-not-exist").exists())

    def test_prerequisite_receipt_invalidates_consumer(self):
        recipe = self.make_recipe([
            {"id": "producer", "command": "echo first > output", "artifacts": ["output"]},
            {"id": "consumer", "needs": ["producer"], "command": "test -s output"},
        ])
        self.assertFalse(self.run_recipe(recipe)[1]["reused"])
        self.assertTrue(self.run_recipe(recipe)[1]["reused"])
        recipe["checks"][0]["command"] = "echo changed > output"
        self.assertFalse(self.run_recipe(recipe)[1]["reused"])

    def test_cancel_while_waiting_for_external_legacy_lock(self):
        recipe = self.make_recipe([{"id": "blocked", "command": "touch should-not-exist"}])
        stop = threading.Event()
        with (self.root / ".git" / "e2e-feature-build.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            with concurrent.futures.ThreadPoolExecutor(1) as pool:
                future = pool.submit(self.run_recipe, recipe, (), stop)
                time.sleep(.05)
                stop.set()
                self.assertEqual(future.result(timeout=2)[0]["status"], "cancelled")
        self.assertFalse((self.root / "should-not-exist").exists())

    def test_cli_cancellation_terminates_running_commands(self):
        pidfile = self.root / ".git" / "child.pid"
        recipe = self.make_recipe([{"id": "long", "command": self.python(f"from pathlib import Path; import os,time; Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(30)")}])
        recipe_path = self.root / ".git" / "recipe.json"
        process = subprocess.Popen([sys.executable, str(test_verify.SCRIPT), "verify", "--feature", "test", "--recipe", str(recipe_path)],
                                   cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 3
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            self.assertTrue(pidfile.exists())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=4)
            self.assertEqual(process.returncode, 130, stderr.decode())
            self.assertEqual(json.loads(stdout)["checks"][0]["status"], "cancelled")
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pidfile.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_snapshot_survives_rebuilding_outputs_but_invalidates_on_source_edit(self):
        (self.root / "output").mkdir()
        (self.root / "output" / "app.js").write_text("feature build")
        result = verify.snapshot(self.root, self.run_dir, self.recipe, ["output"], "pinned")
        manifest = Path(result["manifest"])
        copied = Path(result["artifacts"]["output"]["path"]) / "app.js"
        self.assertFalse(copied.stat().st_mode & 0o222)
        (self.root / "output" / "app.js").write_text("later verification build")
        self.assertTrue(verify.check_snapshot(self.root, self.run_dir, manifest)["ok"])
        self.assertEqual(copied.read_text(), "feature build")
        (self.root / "source").write_text("repair")
        with self.assertRaisesRegex(ValueError, "Source or environment changed"):
            verify.check_snapshot(self.root, self.run_dir, manifest)

    def test_snapshot_detects_tampering_and_dereferences_artifact_links(self):
        (self.root / "output").mkdir()
        (self.root / "output" / "app.js").write_text("feature build")
        (self.root / "output" / "linked.js").symlink_to("app.js")
        result = verify.snapshot(self.root, self.run_dir, self.recipe, ["output"], "pinned")
        copied = Path(result["artifacts"]["output"]["path"])
        self.assertFalse((copied / "linked.js").is_symlink())
        (copied / "app.js").chmod(0o644)
        (copied / "app.js").write_text("tampered")
        with self.assertRaisesRegex(ValueError, "Pinned artifact changed"):
            verify.check_snapshot(self.root, self.run_dir, Path(result["manifest"]))

    def test_invalid_graphs_and_resource_definitions_do_not_run(self):
        invalid = [
            [{"id": "a", "command": "true", "needs": ["missing"]}],
            [{"id": "a", "command": "true", "needs": ["b"]}, {"id": "b", "command": "true", "needs": ["a"]}],
            [{"id": "a", "command": "true", "resources": []}],
            [{"id": "a", "command": "true", "resources": ["unknown"]}],
        ]
        for checks in invalid:
            with self.assertRaises(ValueError):
                self.make_recipe(checks)
        with self.assertRaises(ValueError):
            self.make_recipe([{"id": "a", "command": "true"}], parallel=True)
        with self.assertRaises(ValueError):
            self.make_recipe([{"id": "a", "command": "true"}], resources={"build": {"limit": 2}})


if __name__ == "__main__":
    unittest.main()
