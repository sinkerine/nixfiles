"""Check command boundaries and reservation ownership in the shared launcher."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("agent_job", ROOT / "agent-job.py")
agent_job = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent_job)
PROFILES = json.loads((ROOT / "profiles.json").read_text())


class AgentJobTests(unittest.TestCase):
    def resolve(self, argv, environ=None):
        return agent_job.resolve(argv, qex="/nix/store/test/bin/qex", profiles=PROFILES, environ=environ or {})

    def test_profiles_assign_explicit_claims_and_literal_command_arguments(self):
        command = ["bash", "-c", "printf '%s' '$HOME; $(touch forbidden)'", "--cpu", "99"]
        for name, profile in PROFILES.items():
            with self.subTest(profile=name):
                _, argv = self.resolve(["submit", name, "--", *command])
                self.assertEqual(argv[argv.index("--cpu") + 1], str(profile["cpu"]))
                self.assertEqual(argv[argv.index("--mem") + 1], profile["mem"])
                self.assertEqual(argv[argv.index("--") + 1:], command)
                self.assertIn("AGENT_JOB_ACTIVE=1", argv)

    def test_sync_run_and_async_submit_preserve_qex_lifecycle_choice(self):
        for action in ("run", "submit"):
            _, argv = self.resolve([action, "small", "--timeout", "3m", "--", "true"])
            self.assertEqual(argv[1], action)
            self.assertEqual(argv[argv.index("--timeout") + 1], "3m")

    def test_cwd_id_and_shared_resource_claims(self):
        with tempfile.TemporaryDirectory(prefix="agent-job space ") as directory:
            id_file = str(Path(directory) / "check.id")
            _, argv = self.resolve(["submit", "medium", "--cwd", directory, "--id-file", id_file,
                                    "--heavy-io", "--lock", "device-1", "--", "true"])
            self.assertEqual(argv[argv.index("--cwd") + 1], directory)
            self.assertEqual(argv[argv.index("--id-file") + 1], id_file)
            self.assertEqual(argv[argv.index("--claim") + 1], "heavy-io=1")
            self.assertEqual(argv[argv.index("--lock") + 1], "device-1")

    def test_nested_submission_is_rejected_but_profile_inspection_is_allowed(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as error:
            self.resolve(["submit", "small", "--", "true"], {"AGENT_JOB_ACTIVE": "1"})
        self.assertEqual(error.exception.code, 2)
        args, argv = self.resolve(["profiles", "--json"], {"AGENT_JOB_ACTIVE": "1"})
        self.assertEqual(args.action, "profiles")
        self.assertIsNone(argv)

    def test_invalid_submissions_do_not_produce_executable_commands(self):
        for args in (["submit", "small"], ["submit", "tiny", "--", "true"],
                     ["submit", "small", "--cwd", "/nonexistent-agent-job", "--", "true"],
                     ["submit", "small", "--mem", "1MiB", "--", "true"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.resolve(args)


class RepositoryEstimateTests(unittest.TestCase):
    @staticmethod
    def block(name="browser", entry=None):
        if entry is None:
            entry = {"resources": {"cpu": 3, "mem": "6GiB"}, "timeout": "12m"}
        return f"```qex-e2e {name}\n{json.dumps(entry)}\n```\n"

    def test_named_variants_and_native_qex_resource_fields(self):
        browser = {"resources": {"cpu": 3, "mem": "6GiB", "claims": {"heavy-io": 1}}, "locks": ["device-1"], "timeout": "12m"}
        native = {"resources": {"cpu": 8, "mem": "24GiB"}}
        entries = agent_job.parse_e2e_estimates(self.block(entry=browser) + self.block("native", native))
        self.assertEqual(entries, {"browser": browser, "native": native})

    def test_missing_ambiguous_and_invalid_declarations_fail(self):
        invalid_entries = [
            {}, {"resources": {"cpu": 0, "mem": "6GiB"}},
            {"resources": {"cpu": True, "mem": "6GiB"}},
            {"resources": {"cpu": 2, "mem": "guess"}},
            {"resources": {"cpu": 2, "mem": "25%"}},
            {"resources": {"cpu": 2, "mem": "0GiB"}},
            {"resources": {"cpu": 2, "mem": "0.1B"}},
            {"resources": {"cpu": 2, "mem": "999999999999999999999TiB"}},
            {"resources": {"cpu": 2, "mem": "6GiB", "claims": {"heavy-io": 0}}},
            {"resources": {"cpu": 2, "mem": "6GiB"}, "workers": 1},
            {"resources": {"cpu": 2, "mem": "6GiB"}, "timeout": "later"},
            {"resources": {"cpu": 2, "mem": "6GiB"}, "locks": ["x", "x"]},
        ]
        invalid_texts = ["No resource declarations", self.block() + self.block(),
                         '```qex-e2e browser\n{"resources":{"cpu":1,"cpu":2,"mem":"4GiB"}}\n```\n',
                         '```qex-e2e browser\nnot json\n```\n',
                         '```qex-e2e browser\n{"resources":{"cpu":2,"mem":"6GiB"}}\n']
        for text in [*invalid_texts, *(self.block(entry=e) for e in invalid_entries)]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                agent_job.parse_e2e_estimates(text)

    def test_resolver_reads_root_agents_from_a_subdirectory(self):
        with tempfile.TemporaryDirectory(prefix="agent-job-repo-") as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "AGENTS.md").write_text(self.block(entry={"resources": {"cpu": 3, "mem": "6GiB", "claims": {"heavy-io": 1}}, "timeout": "12m", "locks": ["device-1"]}))
            child = root / "package"
            child.mkdir()
            # A package-local file must not silently override the repository contract.
            (child / "AGENTS.md").write_text(self.block(entry={"resources": {"cpu": 1, "mem": "1GiB"}}))
            resolve = lambda args: agent_job.resolve(args, qex="/qex", profiles=PROFILES, environ={})
            _, argv = resolve(["submit", "--e2e", "browser", "--cwd", str(child), "--", "echo", "literal ; $(value)"])
            self.assertEqual(argv[argv.index("--cpu") + 1], "3")
            self.assertEqual(argv[argv.index("--mem") + 1], "6GiB")
            self.assertEqual(argv[argv.index("--timeout") + 1], "12m")
            self.assertIn("heavy-io=1", argv)
            self.assertIn("device-1", argv)
            self.assertIn("e2e:browser", argv)
            self.assertEqual(argv[-1], "literal ; $(value)")
            args, argv = resolve(["estimates", "--cwd", str(child)])
            self.assertIsNone(argv)
            self.assertEqual(Path(args.agents), root / "AGENTS.md")
            for command in (["submit", "--e2e", "unknown", "--cwd", str(root), "--", "true"],
                            ["submit", "small", "--e2e", "browser", "--cwd", str(root), "--", "true"]):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    resolve(command)
            (root / "AGENTS.md").unlink()
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                resolve(["submit", "--e2e", "browser", "--cwd", str(child), "--", "true"])


@unittest.skipUnless(os.environ.get("QEX_TEST_BINARY"), "set QEX_TEST_BINARY to exercise a built qex")
class QueueIntegrationTests(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("QEX_SHARED_TEST_BINARY"), "set QEX_SHARED_TEST_BINARY to test the installed shared wrapper")
    def test_shared_wrapper_pins_scheduler_roots_and_preserves_job_roots(self):
        script = Path(os.environ["QEX_SHARED_TEST_BINARY"]).read_text()
        raw = os.environ["QEX_TEST_BINARY"]
        self.assertIn(raw, script)
        with tempfile.TemporaryDirectory(prefix="agent-job-shared-") as directory:
            root = Path(directory)
            stub = root / "qex-stub"
            stub.write_text(f"#!{sys.executable}\nimport os,sys,json\nprint(json.dumps(dict(argv=sys.argv[1:],config=os.environ['XDG_CONFIG_HOME'],state=os.environ['XDG_STATE_HOME'])))\n")
            stub.chmod(0o700)
            wrapper = root / "qex"
            wrapper.write_text(script.replace(raw, str(stub)))
            wrapper.chmod(0o700)
            env = {**os.environ, "XDG_CONFIG_HOME": str(root / "project-config"), "XDG_STATE_HOME": str(root / "project-state")}
            literal = "$(touch forbidden); literal argument"
            for action in ("submit", "run"):
                result = subprocess.run([str(wrapper), action, "--cpu", "1", "--", "echo", literal],
                                        env=env, capture_output=True, text=True, check=True)
                data = json.loads(result.stdout)
                self.assertNotEqual(data["config"], env["XDG_CONFIG_HOME"])
                self.assertNotEqual(data["state"], env["XDG_STATE_HOME"])
                self.assertIn(f"XDG_CONFIG_HOME={env['XDG_CONFIG_HOME']}", data["argv"])
                self.assertIn(f"XDG_STATE_HOME={env['XDG_STATE_HOME']}", data["argv"])
                self.assertEqual(data["argv"][-1], literal)
                self.assertFalse((root / "forbidden").exists())
            status = subprocess.run([str(wrapper), "status", "job-id"], env=env, capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(status.stdout)["argv"], ["status", "job-id"])

    def test_two_projects_share_capacity_and_real_job_results(self):
        qex = os.environ["QEX_TEST_BINARY"]
        with tempfile.TemporaryDirectory(prefix="agent-job-integration-") as directory:
            root = Path(directory)
            config = root / "config"
            config.mkdir()
            (config / "qex.toml").write_text(
                '[budget]\ncpu=1\nmem="2GiB"\n'
                '[system]\nreserve_mem="0"\nmax_pressure=100\n'
                '[enforce]\nmode="single-user"\n'
                '[queue]\noversized="reject"\n'
                '[learn]\nenabled=false\n[update]\ncheck="never"\n'
            )
            env = {**os.environ, "XDG_CONFIG_HOME": str(config), "XDG_STATE_HOME": str(root / "state"),
                   "AGENT_JOB_QEX": qex, "AGENT_JOB_PROFILES": str(ROOT / "profiles.json"), "NO_COLOR": "1"}
            env.pop("AGENT_JOB_ACTIVE", None)
            jobs = []
            with (root / "daemon.log").open("w") as log:
                daemon = subprocess.Popen([qex, "daemon", "--foreground"], env=env, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 5
                    while not (root / "state/qex/run/s").exists():
                        self.assertIsNone(daemon.poll(), "private test coordinator exited")
                        self.assertLess(time.monotonic(), deadline, "private coordinator did not become ready")
                        time.sleep(0.05)
                    for name in ("project-a", "project-b"):
                        project = root / name
                        project.mkdir()
                        subprocess.run(["git", "init", "-q", str(project)], check=True)
                        (project / "AGENTS.md").write_text(RepositoryEstimateTests.block(entry={"resources": {"cpu": 1, "mem": "2GiB"}}))
                        script = "import time,json,pathlib,os; a=time.time(); time.sleep(0.8); pathlib.Path('times.json').write_text(json.dumps([a,time.time()])); pathlib.Path('environment.json').write_text(json.dumps({'marker':os.environ.get('QEX_REVIEW_MARKER'),'path':os.environ['PATH']}))"
                        result = subprocess.run([sys.executable, str(ROOT / "agent-job.py"), "submit", "--e2e", "browser",
                                                 "--cwd", str(project), "--", sys.executable, "-c", script],
                                                env={**env, "QEX_REVIEW_MARKER": name, "PATH": str(project / "bin") + os.pathsep + env["PATH"]},
                                                capture_output=True, text=True, timeout=10)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        jobs.append(result.stdout.strip())
                    for job in jobs:
                        result = subprocess.run([qex, "wait", job, "--timeout", "10s"], env=env, capture_output=True, text=True, timeout=15)
                        self.assertEqual(result.returncode, 0, result.stderr)
                    first = json.loads((root / "project-a/times.json").read_text())
                    second = json.loads((root / "project-b/times.json").read_text())
                    self.assertLessEqual(first[1], second[0], "jobs from different projects exceeded the shared budget")
                    for name in ("project-a", "project-b"):
                        captured = json.loads((root / name / "environment.json").read_text())
                        self.assertEqual(captured["marker"], name, "job inherited the coordinator's environment")
                        self.assertTrue(captured["path"].startswith(str(root / name / "bin") + os.pathsep))
                    # The declaration body is also accepted as a native qex job file.
                    native_file = root / "resources.json"
                    for memory in ("2GiB", "2 gib", "2048 mib", "2G"):
                        declaration = {"resources": {"cpu": 1, "mem": memory, "claims": {"review-mutex": 1}}, "timeout": "10s"}
                        agent_job.parse_e2e_estimates(RepositoryEstimateTests.block(entry=declaration))
                        native_file.write_text(json.dumps(declaration))
                        native_result = subprocess.run([qex, "submit", "--wait", "--job", str(native_file), "--", "true"],
                                                       env=env, capture_output=True, text=True, timeout=15)
                        self.assertEqual(native_result.returncode, 0, native_result.stderr)
                    # Undeclared count-one pools are implicit mutexes; larger
                    # counts must fail at submission rather than wait forever.
                    native_file.write_text(json.dumps({"resources": {"cpu": 1, "mem": "2GiB", "claims": {"review-mutex": 2}}}))
                    invalid_pool = subprocess.run([qex, "submit", "--job", str(native_file), "--", "true"],
                                                  env=env, capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(invalid_pool.returncode, 0)
                    self.assertIn("pool", invalid_pool.stderr)
                    rejected = subprocess.run([sys.executable, str(ROOT / "agent-job.py"), "submit", "heavy", "--", "true"],
                                              env=env, capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(rejected.returncode, 0, "oversized profile bypassed the host budget")
                    self.assertNotIn("invalid choice", rejected.stderr, "test must reach qex admission")
                    failed = subprocess.run([sys.executable, str(ROOT / "agent-job.py"), "run", "small", "--", sys.executable, "-c", "raise SystemExit(7)"],
                                            env=env, capture_output=True, text=True, timeout=15)
                    self.assertEqual(failed.returncode, 7, failed.stderr)
                    nested = subprocess.run([sys.executable, str(ROOT / "agent-job.py"), "run", "small", "--", sys.executable,
                                             str(ROOT / "agent-job.py"), "submit", "small", "--", "true"],
                                            env=env, capture_output=True, text=True, timeout=15)
                    self.assertEqual(nested.returncode, 2, nested.stderr)
                finally:
                    for job in jobs:
                        subprocess.run([qex, "kill", job], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                    daemon.terminate()
                    try:
                        daemon.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        daemon.kill()
                        daemon.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
