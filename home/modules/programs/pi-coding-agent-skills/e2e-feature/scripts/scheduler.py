"""Bounded prerequisite scheduling and cross-process verification resource locks."""
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from contextlib import ExitStack
from functools import cache
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import time

NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z")
DEFAULT_RESOURCE = {"scope": "worktree", "limit": 1}


def validate_graph(recipe):
    parallel = recipe.get("max_parallel", 1)
    if type(parallel) is not int or not 1 <= parallel <= 16:
        raise ValueError("max_parallel must be 1..16")
    resources = recipe.get("resources", {})
    if not isinstance(resources, dict):
        raise ValueError("resources must be an object")
    for name, resource in resources.items():
        if not NAME.fullmatch(name) or not isinstance(resource, dict):
            raise ValueError("Resources require safe names and object definitions")
        if set(resource) - {"scope", "limit"} or resource.get("scope", "worktree") not in ("worktree", "repository", "host"):
            raise ValueError(f"{name}: invalid resource scope or fields")
        if type(resource.get("limit", 1)) is not int or not 1 <= resource.get("limit", 1) <= 16:
            raise ValueError(f"{name}: resource limit must be 1..16")
        if name == "build" and resource.get("limit", 1) != 1:
            raise ValueError("The legacy build resource must remain exclusive")
    checks = {check["id"]: check for check in recipe["checks"]}
    for name, check in checks.items():
        needs = check.get("needs", [])
        groups = check.get("resources", ["build"])
        if not isinstance(needs, list) or not all(isinstance(v, str) and v in checks for v in needs) or len(set(needs)) != len(needs):
            raise ValueError(f"{name}: needs must name distinct existing checks")
        if not isinstance(groups, list) or not groups or not all(isinstance(v, str) and (v == "build" or v in resources) for v in groups) or len(set(groups)) != len(groups):
            raise ValueError(f"{name}: resources must name distinct declared groups (or build)")
    visiting, visited = set(), set()
    def visit(name):
        if name in visiting:
            raise ValueError("Check prerequisites contain a cycle")
        if name in visited:
            return
        visiting.add(name)
        for dependency in checks[name].get("needs", []):
            visit(dependency)
        visiting.remove(name)
        visited.add(name)
    for name in checks:
        visit(name)


def select_checks(recipe, ids=(), phase=None):
    """A selection includes its prerequisite closure, even across phase boundaries."""
    by_id = {check["id"]: check for check in recipe["checks"]}
    if set(ids) - by_id.keys():
        raise ValueError("Unknown check id")
    chosen = set()
    def include(name):
        if name in chosen:
            return
        chosen.add(name)
        for dependency in by_id[name].get("needs", []):
            include(dependency)
    for check in recipe["checks"]:
        if (not ids or check["id"] in ids) and (not phase or check.get("phase", "full") == phase):
            include(check["id"])
    if not chosen:
        raise ValueError("No checks selected")
    return [check for check in recipe["checks"] if check["id"] in chosen]


def lock_file(stack, path, mode):
    path.parent.mkdir(parents=True, exist_ok=True)
    handle = stack.enter_context(path.open("a+"))
    fcntl.flock(handle, mode | fcntl.LOCK_NB)
    return handle


def resource_base(git_dir, common_dir, scope):
    if scope == "worktree":
        return git_dir
    if scope == "repository":
        return common_dir
    # Owner-only, host-local locks coordinate different repositories on this host.
    base = Path(tempfile.gettempdir()) / f"e2e-feature-{os.getuid()}"
    base.mkdir(mode=0o700, exist_ok=True)
    if base.is_symlink() or base.stat().st_uid != os.getuid() or base.stat().st_mode & 0o077:
        raise ValueError("Host resource directory must be private and owned by the current user")
    return base


def acquire_resources(git_dir, common_dir, run_dir, recipe, check):
    """Try every lock atomically; never occupy a worker thread waiting for a lock."""
    stack = ExitStack()
    try:
        lock_file(stack, run_dir / "verification" / ".locks" / (check["id"] + ".lock"), fcntl.LOCK_EX)
        groups = check.get("resources", ["build"])
        if "build" not in groups:
            # Unknown commands/legacy workers take this lock exclusively. Explicitly
            # independent commands share it, then claim their narrower resources.
            build = recipe.get("resources", {}).get("build", DEFAULT_RESOURCE)
            base = resource_base(git_dir, common_dir, build.get("scope", "worktree"))
            lock_file(stack, base / "e2e-feature-build.lock", fcntl.LOCK_SH)
        for name in sorted(groups):
            resource = recipe.get("resources", {}).get(name, DEFAULT_RESOURCE)
            scope, limit = resource.get("scope", "worktree"), resource.get("limit", 1)
            base = resource_base(git_dir, common_dir, scope)
            if name == "build" and limit == 1:
                # Preserve interoperability with workers using the existing flock path.
                lock_file(stack, base / "e2e-feature-build.lock", fcntl.LOCK_EX)
                continue
            directory = base / "e2e-feature-resources"
            metadata_lock = lock_file(stack, directory / (name + ".config.lock"), fcntl.LOCK_SH)
            metadata = directory / (name + ".json")
            identity = {"limit": limit}
            try:
                same = json.loads(metadata.read_text()) == identity
            except FileNotFoundError:
                same = False
            if not same:
                # A capacity change waits for all users of the old definition to finish.
                fcntl.flock(metadata_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                metadata.write_text(json.dumps(identity))
                fcntl.flock(metadata_lock, fcntl.LOCK_SH)
            for slot in range(limit):
                handle = (directory / f"{name}.{slot}.lock").open("a+")
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    handle.close()
                else:
                    stack.enter_context(handle)
                    break
            else:
                raise BlockingIOError
        return stack
    except BlockingIOError:
        stack.close()
        return None
    except BaseException:
        stack.close()
        raise


def run_checks(root, git_dir, common_dir, run_dir, recipe, checks, execute, stop=None):
    """Run ready checks, preserving independent results after a sibling failure."""
    stop = stop if stop is not None else threading.Event()
    queued = time.time()
    pending = {check["id"]: check for check in checks}
    results, ready_at, waits, wait_state = {}, {}, {}, {}
    running = {}
    downstream = {name: 0 for name in pending}
    @cache
    def depth(name):
        return 1 + max((depth(other) for other, check in pending.items() if name in check.get("needs", [])), default=0)
    for name in pending:
        downstream[name] = depth(name)
    def perform(check, locks, ready, acquired, timing):
        try:
            result = execute(check, stop)
            result.update(queued_at=queued, ready_at=ready, lock_acquired_at=acquired,
                          ready_to_start_seconds=round(acquired - ready, 3),
                          lock_wait_seconds=round(timing.get("resource", 0), 3),
                          capacity_wait_seconds=round(timing.get("capacity", 0), 3), settled_at=time.time())
            return result
        finally:
            locks.close()
    with ThreadPoolExecutor(max_workers=recipe.get("max_parallel", 1)) as pool:
        try:
            while pending or running:
                if stop.is_set():
                    for name in list(pending):
                        results[name] = {"id": name, "status": "cancelled", "reused": False}
                        del pending[name]
                for name in sorted(list(pending), key=lambda key: (-downstream[key], key)):
                    check = pending[name]
                    needs = check.get("needs", [])
                    if any(dep in results and results[dep]["status"] != "passed" for dep in needs):
                        results[name] = {"id": name, "status": "blocked", "reason": "failed-prerequisite", "needs": needs, "reused": False}
                        del pending[name]
                        continue
                    if not all(dep in results for dep in needs):
                        continue
                    ready_at.setdefault(name, time.time())
                    now = time.monotonic()
                    timing = waits.setdefault(name, {})
                    previous = wait_state.get(name)
                    if previous:
                        since, reason = previous
                        timing[reason] = timing.get(reason, 0) + now - since
                    if len(running) >= recipe.get("max_parallel", 1):
                        wait_state[name] = (now, "capacity")
                        continue
                    locks = acquire_resources(git_dir, common_dir, run_dir, recipe, check)
                    if locks is None:
                        wait_state[name] = (now, "resource")
                        continue
                    wait_state.pop(name, None)
                    acquired = time.time()
                    future = pool.submit(perform, check, locks, ready_at[name], acquired, dict(timing))
                    running[future] = name
                    del pending[name]
                if running:
                    completed, _ = wait(running, timeout=0.05, return_when=FIRST_COMPLETED)
                    for future in completed:
                        name = running.pop(future)
                        try:
                            results[name] = future.result()
                        except Exception as error:
                            results[name] = {"id": name, "status": "error", "error": str(error), "reused": False}
                elif pending:
                    stop.wait(0.05)
        except BaseException:
            stop.set()
            raise
    return [results[check["id"]] for check in checks]
