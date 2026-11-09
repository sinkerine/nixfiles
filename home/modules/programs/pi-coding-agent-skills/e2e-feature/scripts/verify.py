#!/usr/bin/env python3
"""Run recipe checks with evidence bound to source, environment and artifacts."""
import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import threading

from scheduler import run_checks, select_checks, validate_graph


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".receipt-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, indent=2)
            handle.write("\n")
        os.replace(name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(name)


def file_identity(path, ancestors=frozenset()):
    if path.is_symlink():
        # Follow file symlinks too: changing the target content invalidates evidence.
        return ["symlink", os.readlink(path), file_identity(path.resolve(), ancestors)]
    if not path.exists():
        return ["missing"]
    if path.is_file():
        h = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                h.update(block)
        return ["file", path.stat().st_mode & 0o777, h.hexdigest()]
    if path.is_dir():
        identity = str(path.resolve())
        if identity in ancestors:
            return ["cycle", identity]
        return ["directory", [[p.name, file_identity(p, ancestors | {identity})] for p in sorted(path.iterdir())]]
    raise ValueError(f"Unsupported input type: {path}")


def load_recipe(path):
    recipe = json.loads(path.read_text())
    if not isinstance(recipe, dict) or recipe.get("version") != 1 or not isinstance(recipe.get("checks"), list) or not recipe["checks"]:
        raise ValueError("Recipe requires version=1 and a nonempty checks list")
    if set(recipe) - {"version", "checks", "environment_inputs", "env_keys", "max_parallel", "resources"}:
        raise ValueError("Unknown recipe fields")
    for field in ("environment_inputs", "env_keys"):
        if not isinstance(recipe.get(field, []), list) or not all(isinstance(v, str) and v for v in recipe.get(field, [])):
            raise ValueError(f"{field} must be a list of nonempty strings")
    if len(recipe["checks"]) > 64:
        raise ValueError("Recipes support at most 64 checks")
    ids = set()
    for check in recipe["checks"]:
        if not isinstance(check, dict):
            raise ValueError("Each check must be an object")
        if set(check) - {"id", "command", "timeout_seconds", "inputs", "artifacts", "proves", "phase", "needs", "resources"}:
            raise ValueError("Unknown check fields")
        name = check.get("id", "")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", name) or name in ids:
            raise ValueError("Check ids must be unique safe names")
        ids.add(name)
        if not isinstance(check.get("command"), str) or not check["command"].strip() or "\0" in check["command"]:
            raise ValueError(f"{name}: command is required")
        timeout = check.get("timeout_seconds", 120)
        if type(timeout) is not int or not 1 <= timeout <= 86400:
            raise ValueError(f"{name}: timeout_seconds must be 1..86400")
        for field in ("inputs", "artifacts", "proves"):
            if field in check and (not isinstance(check[field], list) or not all(isinstance(v, str) and v for v in check[field])):
                raise ValueError(f"{name}: {field} must be a list of strings")
        if "inputs" in check and not check["inputs"]:
            raise ValueError(f"{name}: omit inputs to fingerprint the whole source tree")
        for item in check.get("inputs", []):
            if Path(item).is_absolute() or ".." in Path(item).parts:
                raise ValueError(f"{name}: source inputs must stay inside the worktree")
        if check.get("phase", "full") not in ("smoke", "task", "full", "e2e"):
            raise ValueError(f"{name}: invalid phase")
    validate_graph(recipe)
    return recipe


def fingerprint(root, recipe, check):
    paths = check.get("inputs", ["."])
    names = git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", *paths).split(b"\0")
    source = []
    for name in sorted(set(os.fsdecode(n) for n in names if n)):
        if name.startswith((".pi/goals/", ".pi/subagents/")) or name in (".pi/pi-goal-x-settings.json", ".pi/.goals-pool-snapshot.json"):
            continue
        source.append((name, file_identity(root / name)))
    # Directory enumeration also covers ignored generated inputs when explicitly named.
    extra = [(name, file_identity(root / name)) for name in recipe.get("environment_inputs", [])]
    env_keys = sorted(set(recipe.get("env_keys", []) + ["PATH", "JAVA_HOME", "ANDROID_HOME", "NIX_PATH", "NIX_PROFILES", "NODE_OPTIONS", "CI", "DISPLAY", "WAYLAND_DISPLAY"]))
    env = {key: os.environ.get(key) for key in env_keys}
    return digest({"runner": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), "source": source, "environment_inputs": extra, "environment": env,
                   "command": check["command"], "timeout": check.get("timeout_seconds", 120),
                   "inputs": paths, "proves": check.get("proves", []), "artifacts": check.get("artifacts", []),
                   "prerequisites": dependency_identities(root, recipe, check)})


def dependency_identities(root, recipe, check):
    # Bind consumers to the exact validated prerequisite receipts, not just their ids.
    directory = recipe.get("_evidence_dir")
    if not directory:
        return []
    identities = []
    for name in check.get("needs", []):
        receipt = json.loads((Path(directory) / f"{name}.json").read_text())
        if receipt.get("status") != "passed":
            raise ValueError(f"{name}: prerequisite has no passing receipt")
        identities.append((name, receipt["fingerprint"], receipt["artifacts"]))
    return identities


def artifacts(root, check):
    return {name: file_identity(root / name) for name in check.get("artifacts", [])}


def execute(command, root, log, timeout, stop=None):
    started = time.monotonic()
    with log.open("wb") as handle:
        child = subprocess.Popen(["bash", "-o", "pipefail", "-c", command], cwd=root,
                                 stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            deadline = started + timeout
            while True:
                if stop is not None and stop.is_set():
                    raise KeyboardInterrupt
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    code = child.wait(timeout=min(0.1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    continue
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            else:
                handle.write(b"\n[e2e-verification] command left live descendants; terminated its process group\n")
                time.sleep(0.05)
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                code = 125
            return code, False, time.monotonic() - started
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            # The shell may exit before a descendant that ignored SIGTERM.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            return 124, True, time.monotonic() - started


def run_check(root, run_dir, recipe, check, refresh=False, stop=None):
    evidence_dir = run_dir / "verification"
    evidence_dir.mkdir(parents=True, exist_ok=True)
    receipt_path = evidence_dir / f"{check['id']}.json"
    before = fingerprint(root, recipe, check)
    if not refresh:
        try:
            previous = json.loads(receipt_path.read_text())
            if (previous.get("version") == 1 and previous.get("status") == "passed"
                    and previous.get("fingerprint") == before and previous.get("command") == check["command"]
                    and Path(previous["log"]).is_file() and previous.get("log_digest") == file_identity(Path(previous["log"]))
                    and previous.get("artifacts") == artifacts(root, check)
                    and all(value != ["missing"] for value in previous["artifacts"].values())):
                return {"id": check["id"], "status": "passed", "reused": True, "receipt": str(receipt_path)}
        except (OSError, KeyError, ValueError):
            pass
    log = evidence_dir / f"{check['id']}-{time.time_ns()}.log"
    started = time.time()
    code, timed_out, duration = execute(check["command"], root, log, check.get("timeout_seconds", 120), stop)
    after = fingerprint(root, recipe, check)
    output_artifacts = artifacts(root, check)
    status = "cancelled" if stop is not None and stop.is_set() else "timed-out" if timed_out else "failed" if code else "stale" if before != after else "passed"
    if status == "passed" and any(value == ["missing"] for value in output_artifacts.values()):
        status = "missing-artifact"
    receipt = {"version": 1, "id": check["id"], "status": status, "exit_code": code,
               "command": check["command"], "fingerprint": before, "after_fingerprint": after,
               "head": git(root, "rev-parse", "HEAD").decode().strip(), "started_at": started,
               "finished_at": time.time(), "duration_seconds": round(duration, 3), "log": str(log),
               "log_digest": file_identity(log), "artifacts": output_artifacts, "proves": check.get("proves", [])}
    atomic_json(receipt_path, receipt)
    return {"id": check["id"], "status": status, "reused": False, "receipt": str(receipt_path), "log": str(log)}


def content_identity(path, ancestors=frozenset()):
    """Compare copied artifacts by content and executability, following symlinks."""
    path = path.resolve(strict=True)
    if path in ancestors:
        raise ValueError("Snapshot artifact contains a symlink cycle")
    if path.is_file():
        return ["file", bool(path.stat().st_mode & 0o111), file_identity(path)[2]]
    if path.is_dir():
        return ["directory", [[child.name, content_identity(child, ancestors | {path})] for child in sorted(path.iterdir())]]
    raise ValueError(f"Unsupported snapshot artifact: {path}")


def snapshot(root, run_dir, recipe, paths, name=None):
    if not paths:
        raise ValueError("snapshot requires at least one --artifact")
    name = name or f"build-{time.time_ns()}"
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", name):
        raise ValueError("snapshot-id must be a safe name")
    for item in paths:
        if Path(item).is_absolute() or ".." in Path(item).parts or item in ("", "."):
            raise ValueError("Snapshot artifacts must be paths inside the worktree")
    identity_recipe = {key: recipe[key] for key in ("environment_inputs", "env_keys") if key in recipe}
    source_check = {"command": "snapshot-source", "inputs": ["."]}
    before = fingerprint(root, identity_recipe, source_check)
    parent = run_dir / "snapshots"
    parent.mkdir(parents=True, exist_ok=True)
    destination = parent / name
    if destination.exists():
        raise ValueError("Snapshot already exists; use a new snapshot-id after a repair")
    temporary = Path(tempfile.mkdtemp(dir=parent, prefix=".snapshot-"))
    try:
        copies = {}
        for index, item in enumerate(paths):
            source, copied = root / item, temporary / str(index)
            expected = content_identity(source)
            if source.is_dir():
                shutil.copytree(source, copied, symlinks=False)
            else:
                shutil.copy2(source, copied, follow_symlinks=True)
            if content_identity(source) != expected or content_identity(copied) != expected:
                raise ValueError(f"Artifact changed while snapshotting: {item}")
            copies[item] = {"path": str(destination / str(index)), "identity": expected}
        if fingerprint(root, identity_recipe, source_check) != before:
            raise ValueError("Source or environment changed while snapshotting")
        manifest = {"version": 1, "root": str(root), "created_at": time.time(),
                    "head": git(root, "rev-parse", "HEAD").decode().strip(),
                    "source_fingerprint": before, "identity_recipe": identity_recipe, "artifacts": copies}
        atomic_json(temporary / "snapshot.json", manifest)
        os.rename(temporary, destination)
        for copied in destination.rglob("*"):
            if copied.is_file():
                copied.chmod(copied.stat().st_mode & 0o555)
        return {"ok": True, "manifest": str(destination / "snapshot.json"), "artifacts": copies,
                "source_fingerprint": before}
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def check_snapshot(root, run_dir, path):
    path = path.resolve(strict=True)
    if not path.is_relative_to((run_dir / "snapshots").resolve()):
        raise ValueError("Snapshot must belong to this feature run")
    manifest = json.loads(path.read_text())
    if manifest.get("version") != 1 or manifest.get("root") != str(root):
        raise ValueError("Snapshot belongs to another checkout or has an unsupported version")
    current = fingerprint(root, manifest["identity_recipe"], {"command": "snapshot-source", "inputs": ["."]})
    if current != manifest["source_fingerprint"]:
        raise ValueError("Source or environment changed; invalidate verification and E2E evidence")
    for item, artifact in manifest["artifacts"].items():
        copied = Path(artifact["path"]).resolve(strict=True)
        if not copied.is_relative_to(path.parent) or content_identity(copied) != artifact["identity"]:
            raise ValueError(f"Pinned artifact changed: {item}")
    return {"ok": True, "manifest": str(path), "source_fingerprint": current}


def main(stop=None):
    stop = stop if stop is not None else threading.Event()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["init", "verify", "handoff", "snapshot", "snapshot-check", "recipe"])
    parser.add_argument("--feature", required=True)
    parser.add_argument("--recipe")
    parser.add_argument("--check", action="append", default=[])
    parser.add_argument("--phase", choices=["smoke", "task", "full", "e2e"])
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--jobs", type=int, help="Lower the recipe concurrency limit for this invocation")
    parser.add_argument("--report")
    parser.add_argument("--sha")
    parser.add_argument("--producer-repo", help="Repository containing the exact dependency commit")
    parser.add_argument("--artifact", action="append", default=[])
    parser.add_argument("--snapshot-id")
    parser.add_argument("--snapshot", help="Manifest returned by snapshot")
    parser.add_argument("--project", choices=["element-web", "element-x-android"])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--smoke-test")
    parser.add_argument("--web-config")
    parser.add_argument("--e2e-spec")
    parser.add_argument("--sdk-repo")
    parser.add_argument("--sdk-sha")
    parser.add_argument("--sdk-api", action="append", default=[])
    parser.add_argument("--abi", choices=["x86_64", "arm64-v8a"], default="x86_64")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,79}", args.feature):
        parser.error("feature must be a lowercase slug")
    root = Path(git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip())
    git_dir = Path(git(root, "rev-parse", "--absolute-git-dir").decode().strip())
    run_dir = git_dir / "e2e-feature" / args.feature
    run_dir.mkdir(parents=True, exist_ok=True)
    if args.action == "recipe":
        if not args.project:
            parser.error("recipe requires --project")
        from projects import make_recipe
        output = (args.output or run_dir / "verification.json").resolve()
        if not output.is_relative_to(root.resolve()) and not output.is_relative_to(run_dir.resolve()):
            parser.error("recipe output must stay within this worktree or feature run directory")
        if output.exists():
            parser.error("recipe output already exists; preserve it or choose a new --output")
        recipe = make_recipe(root, run_dir, args, output)
        # Validate before publishing a recipe, including prerequisite cycles and resources.
        temporary = run_dir / f".recipe-{time.time_ns()}.json"
        try:
            atomic_json(temporary, recipe)
            load_recipe(temporary)
        finally:
            temporary.unlink(missing_ok=True)
        atomic_json(output, recipe)
        print(json.dumps({"ok": True, "recipe": str(output), "checks": [check["id"] for check in recipe["checks"]],
                          "e2e": "automated spec selected" if args.e2e_spec else "requires the approved independent journey"}))
        return 0
    if args.action == "init":
        # Invoking the e2e-feature skill opts this isolated workspace into explicit waits.
        settings = root / ".pi" / "pi-goal-x-settings.json"
        if not settings.parent.resolve().is_relative_to(root.resolve()):
            raise ValueError("Project goal settings must stay inside the worktree")
        value = json.loads(settings.read_text()) if settings.exists() else {}
        if not isinstance(value, dict):
            raise ValueError("Existing project goal settings must be a JSON object")
        value["strictExecutionContract"] = True
        value["idleContinuationBackoff"] = True
        atomic_json(settings, value)
        ignores = settings.parent / ".gitignore"
        if not ignores.exists():
            ignores.write_text("# Worktree-local e2e runtime state\n/.gitignore\n/goals/\n/subagents/\n/pi-goal-x-settings.json\n/.goals-pool-snapshot.json\n")
        print(json.dumps({"run_dir": str(run_dir), "settings": str(settings)}))
        return 0
    if args.action == "handoff":
        if not args.report or not args.sha:
            parser.error("handoff requires --report and --sha")
        if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", args.sha):
            parser.error("handoff requires the exact full commit SHA")
        producer = Path(args.producer_repo).resolve() if args.producer_repo else root
        sha = git(producer, "rev-parse", "--verify", "--end-of-options", args.sha + "^{commit}").decode().strip()
        report = Path(args.report).read_bytes()
        destination = run_dir / "dependency-report.md"
        destination.write_bytes(report)
        result = {"sha": sha, "producer_repo": str(producer), "report": str(destination), "sha256": hashlib.sha256(report).hexdigest()}
        atomic_json(run_dir / "dependency.json", result)
        print(json.dumps(result))
        return 0
    if args.action == "snapshot-check":
        if not args.snapshot:
            parser.error("snapshot-check requires --snapshot")
        print(json.dumps(check_snapshot(root, run_dir, Path(args.snapshot))))
        return 0
    if not args.recipe:
        parser.error(f"{args.action} requires --recipe")
    recipe = load_recipe(Path(args.recipe))
    if args.action == "snapshot":
        print(json.dumps(snapshot(root, run_dir, recipe, args.artifact, args.snapshot_id)))
        return 0
    checks = select_checks(recipe, args.check, args.phase)
    if args.jobs is not None:
        if not 1 <= args.jobs <= recipe.get("max_parallel", 1):
            parser.error("jobs must be positive and cannot exceed the recipe's max_parallel")
        recipe["max_parallel"] = args.jobs
    recipe["_evidence_dir"] = str(run_dir / "verification")
    common_dir = Path(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip())
    started = time.time()
    results = run_checks(root, git_dir, common_dir, run_dir, recipe, checks,
                         lambda check, cancellation: run_check(root, run_dir, recipe, check, args.refresh, cancellation), stop)
    ok = all(result["status"] == "passed" for result in results)
    summary = {"ok": ok, "checks": results, "run_dir": str(run_dir), "started_at": started,
               "finished_at": time.time(), "duration_seconds": round(time.time() - started, 3),
               "max_parallel": recipe.get("max_parallel", 1),
               "lock_wait_seconds": round(sum(result.get("lock_wait_seconds", 0) for result in results), 3)}
    atomic_json(run_dir / "verification" / "latest-run.json", summary)
    print(json.dumps(summary))
    return 130 if stop.is_set() else 0 if ok else 1


if __name__ == "__main__":
    cancellation = threading.Event()
    def interrupted(_signal, _frame):
        cancellation.set()
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        sys.exit(main(cancellation))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        sys.exit(1)
