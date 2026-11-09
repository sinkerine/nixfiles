"""Concrete recipe generation and environment checks for maintained projects."""
import argparse
from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import zipfile


def command(*argv):
    return shlex.join([str(value) for value in argv])


def require(condition, message):
    if not condition:
        raise ValueError(message)


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def web_environment(root):
    package = json.loads((root / "package.json").read_text())
    expected = package.get("devEngines", {}).get("packageManager", {}).get("version")
    actual = subprocess.check_output(["corepack", "pnpm", "--version"], text=True).strip()
    require(not expected or actual == expected, f"Expected pnpm {expected}, found {actual}")
    config = (root / "vitest.config.ts").read_text()
    require('"{apps,modules,packages}/*/vitest.config.ts"' in config,
            "Root test discovery changed; regenerate and review the full check inventory")
    require((root / "packages/shared-components/__vis__/linux").is_dir(), "Linux Storybook baselines are missing")
    require(os.environ.get("CI") == "1", "Use CI=1 to select existing Linux baselines")
    require(os.environ.get("PW_TEST_CONNECT_WS_ENDPOINT"), "Enter the pinned Playwright container environment first; PW_TEST_CONNECT_WS_ENDPOINT is missing")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", os.environ.get("E2E_BROWSER_IMAGE_DIGEST", "")),
            "Set E2E_BROWSER_IMAGE_DIGEST to the actual pinned browser image digest")
    # This exercises the real browser without changing test baselines or starting a shared server.
    probe = """const {chromium}=require('@playwright/test');
(async()=>{ const b=await chromium.connect(process.env.PW_TEST_CONNECT_WS_ENDPOINT);
try {const p=await b.newPage(); await p.setContent('<button>smoke</button>');
if(await p.getByRole('button',{name:'smoke'}).count()!==1) throw Error('browser smoke failed');
await p.close();} finally {await b.close();}})().catch(e=>{console.error(e.message);process.exitCode=1});"""
    subprocess.run(["node", "-e", probe], cwd=root, check=True, timeout=30)
    return {"pnpm": actual, "browser_image": os.environ["E2E_BROWSER_IMAGE_DIGEST"], "baseline_platform": "linux"}


def sdk_environment(root, repository, sha, abi, aar_sha, requirements):
    require(re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", sha), "SDK delivery needs an exact full SHA")
    require(git(repository, "rev-parse", "--verify", "--end-of-options", sha + "^{commit}") == sha.lower(), "SDK commit did not resolve exactly")
    for requirement in requirements:
        source_path, symbol = requirement.rsplit(":", 1)
        require(not Path(source_path).is_absolute() and ".." not in Path(source_path).parts and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", symbol), "Invalid SDK API requirement")
        source = git(repository, "show", sha + ":" + source_path)
        require(re.search(r"\bfn\s+" + re.escape(symbol) + r"\s*\(", source), f"SDK {sha} lacks {symbol} in {source_path}")
    aar = root / "libraries/rustsdk/matrix-rust-sdk.aar"
    require(hashlib.sha256(aar.read_bytes()).hexdigest() == aar_sha, "Installed AAR differs from the pinned delivery; validate the new delivery and regenerate its recipe")
    with zipfile.ZipFile(aar) as archive, tempfile.TemporaryDirectory(prefix="e2e-sdk-") as temporary:
        require(f"jni/{abi}/libmatrix_sdk_ffi.so" in archive.namelist(), f"AAR has no {abi} native library")
        jar = Path(temporary) / "classes.jar"
        jar.write_bytes(archive.read("classes.jar"))
        bindings = subprocess.check_output(["javap", "-classpath", str(jar), "org.matrix.rustcomponents.sdk.Client", "org.matrix.rustcomponents.sdk.Timeline"], text=True)
        for symbol in ["threadInboxPager", "threadInboxUnread", "subscribeToThreadInboxUpdates", "sendWithExtraContent", "sendReplyWithExtraContent"]:
            require(re.search(r"\b" + symbol + r"\(", bindings), f"AAR bindings lack required existing/new API {symbol}")
    for name in ["JAVA_HOME", "ANDROID_HOME", "ANDROID_NDK_HOME"]:
        require(os.environ.get(name) and Path(os.environ[name]).is_dir(), f"Enter this checkout's Nix dev shell; {name} is unavailable")
    version = subprocess.run(["java", "-version"], capture_output=True, text=True, check=True)
    require(re.search(r'version "21[.\"]', version.stderr + version.stdout), "Android recipe requires JDK 21")
    return {"sdk_sha": sha, "aar_sha256": aar_sha, "abi": abi, "apis": requirements}


def make_recipe(root, run_dir, args, output):
    helper = Path(__file__).resolve()
    python = sys.executable
    run = lambda *argv: command(python, helper, *argv)
    if args.project == "element-web":
        require((root / "apps/web/project.json").is_file(), "This is not the supported Element Web monorepo")
        smoke = args.smoke_test or "apps/web/src/utils/arrays.test.ts"
        require((root / smoke).is_file(), "Select an existing --smoke-test from the approved checkout")
        legacy = sorted((root / "apps/web/test").glob("**/*-test.*"))
        if args.e2e_spec:
            require(args.web_config and Path(args.web_config).is_file(), "Automated Web E2E needs --web-config pointing to the approved isolated config.json")
        journey_endpoint = os.environ.get("E2E_PW_TEST_CONNECT_WS_ENDPOINT")
        separate_browser = bool(journey_endpoint and journey_endpoint != os.environ.get("PW_TEST_CONNECT_WS_ENDPOINT"))
        build_command = "NX_DAEMON=false corepack pnpm --dir apps/web build"
        if args.web_config:
            build_command += " && " + command("cp", Path(args.web_config).resolve(), "apps/web/webapp/config.json")
        checks = [
            {"id": "environment", "phase": "smoke", "command": "CI=1 " + run("web-environment"), "timeout_seconds": 60},
            {"id": "prepare", "phase": "task", "needs": ["environment"], "command": "corepack pnpm exec nx run-many -t test:unit:prepare && corepack pnpm --dir apps/desktop exec tsc", "timeout_seconds": 900},
            {"id": "test-smoke", "phase": "task", "needs": ["prepare"], "command": "CI=1 NX_DAEMON=false corepack pnpm exec vitest run " + shlex.quote(smoke), "timeout_seconds": 60},
            {"id": "discovery", "needs": ["pin-build"], "command": "CI=1 corepack pnpm exec vitest list --json", "resources": ["browser", "host-cpu"], "timeout_seconds": 120},
            {"id": "units-coverage", "needs": ["discovery"], "command": "CI=1 NX_DAEMON=false corepack pnpm exec vitest run --coverage --maxWorkers=2", "resources": ["browser", "host-cpu"], "timeout_seconds": 1800, "artifacts": ["coverage/lcov.info"], "proves": ["all-configured-vitest-projects", "unit-and-browser-and-storybook", "coverage"]},
            {"id": "lint", "needs": ["pin-build"], "command": "NX_DAEMON=false corepack pnpm lint", "resources": ["lint", "host-cpu"], "timeout_seconds": 1200},
            {"id": "i18n", "needs": ["prepare"], "command": "corepack pnpm i18n && git diff --exit-code", "timeout_seconds": 300},
            {"id": "app-build", "needs": ["i18n"], "command": build_command, "timeout_seconds": 1200, "artifacts": ["apps/web/webapp"]},
            {"id": "pin-build", "needs": ["app-build"], "command": run("pin", "--feature", args.feature, "--recipe", output, "--artifact", "apps/web/webapp"), "resources": ["app-output"], "artifacts": [str(run_dir / "pinned-build.json")]},
        ]
        reports = ["coverage/lcov.info"]
        if legacy:
            checks.append({"id": "legacy-jest-coverage", "needs": ["pin-build"], "command": "CI=1 corepack pnpm --dir apps/web exec jest --coverage", "resources": ["legacy-jest", "host-cpu"], "timeout_seconds": 1800, "artifacts": ["apps/web/coverage/lcov.info"]})
            reports.append("apps/web/coverage/lcov.info")
        checks.append({"id": "diff-coverage", "needs": ["units-coverage"] + (["legacy-jest-coverage"] if legacy else []),
                       "command": run("coverage", *reports) + " && " + command("diff-cover", "--config-file", "diff-cover.toml", *reports), "resources": ["coverage-report"], "timeout_seconds": 120})
        if args.e2e_spec:
            require(not Path(args.e2e_spec).is_absolute() and ".." not in Path(args.e2e_spec).parts, "E2E spec must stay within apps/web")
            require((root / "apps/web" / args.e2e_spec).is_file(), "The approved E2E spec does not exist")
            checks.append({"id": "e2e", "phase": "e2e", "needs": ["pin-build"], "command": run("web-e2e", "--feature", args.feature, "--spec", args.e2e_spec), "resources": ["e2e-browser" if separate_browser else "browser", "host-cpu"], "timeout_seconds": 1800, "proves": ["approved-feature-journey"]})
        return {"version": 1, "max_parallel": 2, "resources": {"host-cpu": {"scope": "host", "limit": 2}, **{name: {} for name in ["browser", "e2e-browser", "lint", "app-output", "coverage-report", "legacy-jest"]}},
                "environment_inputs": ["node_modules/.modules.yaml", "node_modules/.pnpm/lock.yaml", "flake.lock"] + ([str(Path(args.web_config).resolve())] if args.web_config else []),
                "env_keys": ["PW_TEST_CONNECT_WS_ENDPOINT", "E2E_BROWSER_IMAGE_DIGEST", "E2E_PW_TEST_CONNECT_WS_ENDPOINT", "E2E_JOURNEY_BROWSER_IMAGE_DIGEST", "NX_DAEMON"], "checks": checks}
    require(args.sdk_repo and args.sdk_sha, "Android recipes require --sdk-repo and --sdk-sha from the verified delivery")
    aar = root / "libraries/rustsdk/matrix-rust-sdk.aar"
    aar_sha = hashlib.sha256(aar.read_bytes()).hexdigest()
    requirements = ["bindings/matrix-sdk-ffi/src/client.rs:" + symbol for symbol in ["thread_inbox_pager", "thread_inbox_unread", "subscribe_to_thread_inbox_updates"]]
    requirements += ["bindings/matrix-sdk-ffi/src/timeline/mod.rs:" + symbol for symbol in ["send_with_extra_content", "send_reply_with_extra_content"]]
    requirements += args.sdk_api
    sdk_command = run("sdk-environment", "--sdk-repo", Path(args.sdk_repo).resolve(), "--sdk-sha", args.sdk_sha, "--abi", args.abi, "--aar-sha256", aar_sha)
    for requirement in requirements:
        sdk_command += " " + command("--require", requirement)
    return {"version": 1, "max_parallel": 1, "resources": {"gradle": {"scope": "repository"}},
            "environment_inputs": ["flake.lock", "libraries/rustsdk/matrix-rust-sdk.aar", "gradle/wrapper/gradle-wrapper.properties"],
            "env_keys": ["JAVA_HOME", "ANDROID_HOME", "ANDROID_NDK_HOME"], "checks": [
                {"id": "sdk-compatibility", "phase": "smoke", "command": sdk_command, "timeout_seconds": 60},
                {"id": "units", "needs": ["sdk-compatibility"], "command": "./tools/gradle-local.sh test", "resources": ["gradle"], "timeout_seconds": 3600, "proves": ["existing-unit-tests"]},
                {"id": "lint", "needs": ["sdk-compatibility"], "command": "./tools/gradle-local.sh lint", "resources": ["gradle"], "timeout_seconds": 3600},
                {"id": "app-build", "needs": ["units", "lint"], "command": "./tools/gradle-local.sh :app:assembleGplayDebug", "resources": ["gradle"], "timeout_seconds": 3600, "artifacts": [f"app/build/outputs/apk/gplay/debug/app-gplay-{args.abi}-debug.apk"]},
                {"id": "pin-build", "needs": ["app-build"], "command": run("pin", "--feature", args.feature, "--recipe", output, "--artifact", f"app/build/outputs/apk/gplay/debug/app-gplay-{args.abi}-debug.apk"), "resources": ["gradle"], "artifacts": [str(run_dir / "pinned-build.json")]},
            ]}


def pin(root, run_dir, recipe_path, artifact):
    from verify import atomic_json, load_recipe, snapshot
    result = snapshot(root, run_dir, load_recipe(recipe_path), [artifact])
    atomic_json(run_dir / "pinned-build.json", result)
    return result


def web_e2e(root, run_dir, spec):
    from verify import check_snapshot
    pinned = json.loads((run_dir / "pinned-build.json").read_text())
    manifest = Path(pinned["manifest"])
    check_snapshot(root, run_dir, manifest)
    artifact = Path(pinned["artifacts"]["apps/web/webapp"]["path"])
    require((artifact / "config.json").is_file(), "Pinned build needs the isolated E2E config.json before snapshotting")
    handler = partial(SimpleHTTPRequestHandler, directory=str(artifact))
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        env = dict(os.environ, CI="1", BASE_URL=f"http://127.0.0.1:{server.server_port}")
        if os.environ.get("E2E_PW_TEST_CONNECT_WS_ENDPOINT"):
            require(re.fullmatch(r"sha256:[0-9a-f]{64}", os.environ.get("E2E_JOURNEY_BROWSER_IMAGE_DIGEST", "")), "Pin the separate journey browser image digest")
            env["PW_TEST_CONNECT_WS_ENDPOINT"] = os.environ["E2E_PW_TEST_CONNECT_WS_ENDPOINT"]
        subprocess.run(["corepack", "pnpm", "--dir", "apps/web", "test:playwright", "--", spec, "--project=Chrome"], cwd=root, env=env, check=True)
        check_snapshot(root, run_dir, manifest)
        return {"ok": True, "manifest": str(manifest), "spec": spec}
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["web-environment", "sdk-environment", "pin", "web-e2e", "coverage"])
    parser.add_argument("reports", nargs="*")
    parser.add_argument("--feature")
    parser.add_argument("--recipe", type=Path)
    parser.add_argument("--artifact")
    parser.add_argument("--spec")
    parser.add_argument("--sdk-repo", type=Path)
    parser.add_argument("--sdk-sha")
    parser.add_argument("--abi", choices=["x86_64", "arm64-v8a"], default="x86_64")
    parser.add_argument("--aar-sha256")
    parser.add_argument("--require", action="append", default=[])
    args = parser.parse_args()
    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
    run_dir = Path(git(root, "rev-parse", "--absolute-git-dir")) / "e2e-feature" / (args.feature or "unused")
    if args.action == "web-environment":
        result = web_environment(root)
    elif args.action == "sdk-environment":
        result = sdk_environment(root, args.sdk_repo, args.sdk_sha, args.abi, args.aar_sha256, args.require)
    elif args.action == "pin":
        result = pin(root, run_dir, args.recipe, args.artifact)
    elif args.action == "web-e2e":
        result = web_e2e(root, run_dir, args.spec)
    else:
        require(args.reports, "Expected coverage report paths")
        for report in args.reports:
            text = Path(report).read_text()
            require("SF:" in text and "DA:" in text, f"Coverage report is empty or invalid: {report}")
        result = {"ok": True, "reports": args.reports}
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        sys.exit(1)
