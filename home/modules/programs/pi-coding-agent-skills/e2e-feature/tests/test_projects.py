import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
from urllib.request import urlopen

from unittest.mock import patch

import test_verify
import projects
from projects import make_recipe
from scheduler import select_checks

benchmark_spec = importlib.util.spec_from_file_location("review_benchmark", test_verify.SCRIPT.parent / "benchmark.py")
benchmark = importlib.util.module_from_spec(benchmark_spec)
benchmark_spec.loader.exec_module(benchmark)


class ProjectTests(unittest.TestCase):
    setUp = test_verify.VerificationTests.setUp
    git = test_verify.VerificationTests.git

    def options(self, **values):
        defaults = dict(project="element-web", feature="test", smoke_test=None, e2e_spec=None, web_config=None,
                        sdk_repo=None, sdk_sha=None, sdk_api=[], abi="x86_64")
        return argparse.Namespace(**(defaults | values))

    def web_fixture(self):
        for name in ["apps/web/project.json", "apps/web/src/utils/arrays.test.ts", "apps/web/playwright/e2e/feature.spec.ts"]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("{}")
        config = self.root / ".git" / "config.json"
        config.write_text('{"default_server_config":{}}')
        return config

    def validate(self, recipe):
        path = self.root / ".git" / "recipe.json"
        path.write_text(json.dumps(recipe))
        return test_verify.verify.load_recipe(path)

    def test_web_inventory_and_isolated_e2e_prerequisites(self):
        config = self.web_fixture()
        args = self.options(e2e_spec="playwright/e2e/feature.spec.ts", web_config=str(config))
        with patch.dict("os.environ", {"PW_TEST_CONNECT_WS_ENDPOINT": "http://unit-browser", "E2E_PW_TEST_CONNECT_WS_ENDPOINT": "http://journey-browser"}):
            recipe = self.validate(make_recipe(self.root, self.run_dir, args, self.run_dir / "recipe.json"))
        checks = {check["id"]: check for check in recipe["checks"]}
        self.assertIn("all-configured-vitest-projects", checks["units-coverage"]["proves"])
        self.assertNotIn("--project", checks["units-coverage"]["command"])
        self.assertEqual(checks["e2e"]["resources"], ["e2e-browser", "host-cpu"])
        self.assertEqual(checks["e2e"]["needs"], ["pin-build"])
        self.assertIn("pin-build", checks["lint"]["needs"])
        self.assertIn("pin-build", checks["discovery"]["needs"])
        self.assertNotIn("resources", checks["app-build"], "Generators/builds remain exclusive before readers")
        self.assertIn("apps/desktop/lib", checks["prepare"]["artifacts"])
        self.assertIn("apps/desktop/lib", checks["units-coverage"]["environment_inputs"])
        self.assertEqual([c["id"] for c in select_checks(recipe, phase="smoke")], ["environment"])

    def test_web_preserves_legacy_jest_and_shared_browser_conflicts(self):
        self.web_fixture()
        legacy = self.root / "apps/web/test/example-test.ts"
        legacy.parent.mkdir(parents=True)
        legacy.touch()
        recipe = self.validate(make_recipe(self.root, self.run_dir, self.options(), self.run_dir / "recipe.json"))
        checks = {check["id"]: check for check in recipe["checks"]}
        self.assertIn("legacy-jest-coverage", checks)
        self.assertIn("legacy-jest-coverage", checks["diff-coverage"]["needs"])
        self.assertIn("apps/web/coverage/lcov.info", checks["diff-coverage"]["command"])
        with self.assertRaisesRegex(ValueError, "web-config"):
            make_recipe(self.root, self.run_dir, self.options(e2e_spec="playwright/e2e/feature.spec.ts"), self.run_dir / "recipe.json")

    def test_android_keeps_build_and_emulator_serial_and_pins_sdk(self):
        aar = self.root / "libraries/rustsdk/matrix-rust-sdk.aar"
        aar.parent.mkdir(parents=True)
        aar.write_bytes(b"test artifact")
        args = self.options(project="element-x-android", sdk_repo=str(self.root), sdk_sha="a" * 40)
        recipe = self.validate(make_recipe(self.root, self.run_dir, args, self.run_dir / "recipe.json"))
        checks = {check["id"]: check for check in recipe["checks"]}
        self.assertEqual(recipe["max_parallel"], 1)
        self.assertNotIn("e2e", checks)
        self.assertIn("thread_inbox_pager", checks["sdk-compatibility"]["command"])
        self.assertIn("send_reply_with_extra_content", checks["sdk-compatibility"]["command"])
        self.assertEqual(checks["app-build"]["needs"], ["units", "lint"])
        self.assertIn("./tools/gradle-local.sh", checks["units"]["command"])

    def test_pinned_web_journey_uses_owned_server_and_survives_mutable_build_outputs(self):
        (self.root / ".gitignore").write_text("generated\noutput\n.pi/\napps/web/webapp/\n")
        self.git("add", ".gitignore")
        self.git("commit", "-qm", "ignore build output")
        build = self.root / "apps/web/webapp"
        build.mkdir(parents=True)
        (build / "config.json").write_text('{"isolated":true}')
        (build / "index.html").write_text("pinned feature")
        recipe_path = self.root / ".git" / "recipe.json"
        recipe_path.write_text(json.dumps(self.recipe))
        projects.pin(self.root, self.run_dir, recipe_path, "apps/web/webapp")
        (build / "index.html").write_text("unrelated later build")
        real_run = subprocess.run
        def run(argv, **kwargs):
            if argv[0] != "corepack":
                return real_run(argv, **kwargs)
            base = kwargs["env"]["BASE_URL"]
            self.assertTrue(base.startswith("http://127.0.0.1:"))
            with urlopen(base + "/index.html") as response:
                self.assertEqual(response.read(), b"pinned feature")
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(projects.subprocess, "run", side_effect=run):
            self.assertTrue(projects.web_e2e(self.root, self.run_dir, "playwright/e2e/feature.spec.ts")["ok"])

    def test_sdk_check_rejects_missing_retained_api_before_any_build(self):
        api = self.root / "ffi.rs"
        api.write_text("pub fn thread_inbox_pager() {}")
        self.git("add", "ffi.rs")
        self.git("commit", "-qm", "SDK snapshot")
        sha = self.git("rev-parse", "HEAD").decode().strip()
        with self.assertRaisesRegex(ValueError, "lacks thread_inbox_unread"):
            projects.sdk_environment(self.root, self.root, sha, "x86_64", "unused", ["ffi.rs:thread_inbox_unread"])

    def test_generated_recipe_never_lowers_existing_coverage_threshold(self):
        self.web_fixture()
        (self.root / "diff-cover.toml").write_text("[tool.diff_cover]\nfail_under = 95\n")
        recipe = make_recipe(self.root, self.run_dir, self.options(), self.run_dir / "recipe.json")
        check = next(check for check in recipe["checks"] if check["id"] == "diff-coverage")
        self.assertIn("--fail-under 95", check["command"])

    def test_benchmark_packet_hides_ground_truth_and_scores_only_provisional_matches(self):
        definition = {"contract": "Check behavior", "files": [{"path": "source"}]}
        packet = benchmark.packet(self.root, self.git("rev-parse", "HEAD").decode().strip(), definition)
        self.assertIn("original", packet)
        self.assertNotIn("expected", packet)
        report = benchmark.parse_report('{"findings":[{"path":"source","symbol":"f","severity":"Important","summary":"gallery failure","evidence":"it will throw"}],"limitations":[]}')
        quality = benchmark.score(report, [{"id": "known", "path": "source", "terms": ["gallery", "throw"]}])
        self.assertEqual(quality["candidate_matches"][0]["candidate_findings"], [0])
        self.assertTrue(quality["requires_adjudication"])
        with self.assertRaises(ValueError):
            benchmark.parse_report('{"findings":[{"severity":"Important"}]}')

    def test_benchmark_cli_is_tool_free_and_retains_measured_usage(self):
        fake = self.root / ".git" / "fake-pi"
        fake.write_text("#!" + sys.executable + "\nimport json,sys\nprompt=sys.stdin.read()\nassert '--no-tools' in sys.argv and '--no-extensions' in sys.argv and '--no-context-files' in sys.argv\nprint(json.dumps({'type':'message_end','message':{'role':'assistant','model':'test-model','content':[{'type':'text','text':'{\\\"findings\\\":[],\\\"limitations\\\":[]}'}],'usage':{'input':12,'output':3},'stopReason':'stop'}}))\n")
        fake.chmod(0o755)
        result = benchmark.run_cell(str(fake), "provider/model:low", "code packet", self.root / ".git" / "result", 5)
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["tool_calls"], 0)
        self.assertEqual(result["usage"]["input"], 12)
        self.assertEqual(result["resolved_model"], "test-model")


if __name__ == "__main__":
    unittest.main()
