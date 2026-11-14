#!/usr/bin/env python3
"""Move active Paseo workspace agent tabs between hosts.

`workspace-dispatch out` moves running and idle agent tabs from kazuki to sachi;
`workspace-dispatch back` returns them from either host. Tabs sharing files move
as one workspace, with a transcript and handoff for each replacement agent.
Registered e2e-feature agents retain their specialized resume protocol.

The source is frozen until every replacement starts. A failed startup archives
partial destination agents before thawing the source. Home directories are kept
and checked for changes before returning. This does not preserve live provider
sessions, terminal processes, Pi goals, or subagent runtime ids.

The same Python source is streamed over SSH to both hosts. `e2e-dispatch` remains
an alias, including its `register` command for e2e-feature workflows.
"""

import argparse
import base64
import datetime
import fcntl
import glob
import hashlib
import re
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

HOSTS = {
    "kazuki": {"ssh": "kazuki", "paseo": "tcp://paeso.kazuki.m.mado.moe:443?ssl=true"},
    "sachi": {"ssh": "sachi", "paseo": "tcp://paeso.sachi.m.mado.moe:443?ssl=true"},
}
HOME = os.environ.get("WORKSPACE_DISPATCH_HOME", os.environ.get("E2E_DISPATCH_HOME", "kazuki"))
AWAY = os.environ.get("WORKSPACE_DISPATCH_AWAY", os.environ.get("E2E_DISPATCH_AWAY", "sachi"))
ACTIVE = ("running", "idle")
# Outgoing dispatch only; existing away copies can still be recovered with back.
DISPATCH_PROJECT_DENYLIST = frozenset({"tiny-llm"})
REF_NS = "refs/e2e-dispatch"
# Pi's goal files and subagent state are per host and per session; they never move.
PI_STATE_DIR = ".pi"
REWRITE_SUFFIXES = (".md", ".json", ".sh", ".txt", ".js")
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]
IN_PROGRESS_MARKERS = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "rebase-merge", "rebase-apply")


class Failure(Exception):
    pass


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def log(message):
    # The caller may be the very orchestrator this move kills (for example over SSH), so a
    # vanished stderr must not stop the move.
    try:
        print(f"[workspace-dispatch] {message}", file=sys.stderr, flush=True)
    except (BrokenPipeError, OSError):
        pass


def say(message):
    """print() that survives a caller that has gone away."""
    try:
        print(message, flush=True)
    except (BrokenPipeError, OSError):
        pass


def run(args, cwd=None, input=None, env=None, check=True):
    result = subprocess.run(args, cwd=cwd, input=input, env=env, capture_output=True, text=True)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise Failure(f"`{shlex.join(args)}` failed ({result.returncode}): {detail}")
    return result.stdout


def git(worktree, *args, env=None, check=True):
    return run(["git", "-C", worktree, *args], env=env, check=check)


def pipe(first, second):
    """Run `first | second` on raw bytes, so binary patches survive."""
    producer = subprocess.Popen(first, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    consumer = subprocess.run(second, stdin=producer.stdout, capture_output=True)
    producer.stdout.close()
    producer_err = producer.stderr.read().decode(errors="replace")
    producer.stderr.close()
    if producer.wait() != 0:
        raise Failure(f"`{shlex.join(first)}` failed: {producer_err.strip()}")
    if consumer.returncode != 0:
        raise Failure(f"`{shlex.join(second)}` failed: {consumer.stderr.decode(errors='replace').strip()}")


# ---------------------------------------------------------------------------
# Host-local helpers. Each one runs on the host that owns the files or processes,
# directly or through `ssh <host> python3 - _helper <payload>`.
# ---------------------------------------------------------------------------


def git_dir(worktree):
    return git(worktree, "rev-parse", "--absolute-git-dir").strip()


def tree_of(worktree):
    """Tree id of the worktree as it is on disk, untracked files included, without touching the index.

    Pi's state directory keeps its committed content, if any: anything untracked or edited there
    stays on this host. (An exclude pathspec would fail outright where `.pi` is gitignored.)
    """
    with tempfile.TemporaryDirectory() as scratch:
        env = {**os.environ, "GIT_INDEX_FILE": os.path.join(scratch, "index")}
        git(worktree, "read-tree", "HEAD", env=env)
        git(worktree, "add", "-A", "--", ".", env=env)
        git(worktree, "reset", "-q", "HEAD", "--", PI_STATE_DIR, env=env)
        return git(worktree, "write-tree", env=env).strip()


def operation_in_progress(worktree):
    directory = git_dir(worktree)
    return [marker for marker in IN_PROGRESS_MARKERS if os.path.exists(os.path.join(directory, marker))]


def h_ping():
    return {"host": socket.gethostname(), "home": os.path.expanduser("~")}


def h_read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return None


def h_write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = f"{path}.tmp"
    with open(temporary, "w") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)
    return path


def h_mkdir(path):
    os.makedirs(path, exist_ok=True)
    return path


def h_tree_of(worktree):
    return tree_of(worktree)


def h_git_dir(worktree):
    return git_dir(worktree)


def h_worktree_state(worktree):
    """What the dispatcher needs to know about a worktree before moving its run."""
    head = git(worktree, "rev-parse", "HEAD").strip()
    branch = git(worktree, "symbolic-ref", "--short", "-q", "HEAD", check=False).strip()
    return {"head": head, "branch": branch, "gitDir": git_dir(worktree), "inProgress": operation_in_progress(worktree)}


def h_log_subjects(worktree, base):
    """Commit subjects on the branch since base (the last 300 when this host lacks the base ref)."""
    has_base = bool(base) and subprocess.run(["git", "-C", worktree, "rev-parse", "-q", "--verify", f"{base}^{{commit}}"],
                                             capture_output=True).returncode == 0
    args = ["log", "--format=%H %s"] + ([f"{base}..HEAD"] if has_base else ["-n", "300", "HEAD"])
    out = git(worktree, *args, check=False)
    return [line.split(" ", 1) for line in out.splitlines() if " " in line]


def h_snapshot(worktree, feature, seq):
    if (busy := operation_in_progress(worktree)):
        raise Failure(f"{worktree} has a git operation in progress ({', '.join(busy)}); finish or abort it first")
    head = git(worktree, "rev-parse", "HEAD").strip()
    branch = git(worktree, "symbolic-ref", "--short", "-q", "HEAD", check=False).strip()
    tree = tree_of(worktree)
    commit = git(worktree, "commit-tree", tree, "-p", head, "-m", f"e2e-dispatch snapshot of {feature} (move {seq})").strip()
    head_ref = f"{REF_NS}/{feature}/head-{seq}"
    snapshot_ref = f"{REF_NS}/{feature}/snapshot-{seq}"
    git(worktree, "update-ref", head_ref, head)
    git(worktree, "update-ref", snapshot_ref, commit)
    stat = git(worktree, "diff", "--stat", head, commit)
    return {"head": head, "branch": branch, "tree": tree, "commit": commit,
            "headRef": head_ref, "snapshotRef": snapshot_ref, "wipStat": stat[-4000:]}


def verify_tree(worktree, expected):
    actual = tree_of(worktree)
    if actual == expected:
        return []
    changes = git(worktree, "diff", "--name-status", "--no-renames", expected, actual).splitlines()
    extra = [line for line in changes if line.startswith("A\t")]
    wrong = [line for line in changes if not line.startswith("A\t")]
    if wrong:
        raise Failure(f"{worktree} does not match the snapshot:\n" + "\n".join(wrong[:40]))
    # Files that exist only here (for example, written by a worktree setup script) are reported, not fatal.
    return [f"present only on this host: {line[2:]}" for line in extra[:40]]


def apply_range(worktree, start, end):
    pipe(["git", "-C", worktree, "diff", "--binary", "--full-index", start, end],
         # A run parked with everything committed has an empty snapshot diff.
         ["git", "-C", worktree, "apply", "--allow-empty", "--whitespace=nowarn", "-"])


def h_apply_snapshot(worktree, snapshot_ref, expected_tree):
    """Recreate the uncommitted work of a snapshot in a fresh worktree checked out at its parent."""
    apply_range(worktree, "HEAD", snapshot_ref)
    return verify_tree(worktree, expected_tree)


def h_adopt_incoming(worktree, head_ref, snapshot_ref, expected_tree, departure_tree):
    """Bring a kept worktree to an incoming snapshot, refusing if anything changed since the run left."""
    if (busy := operation_in_progress(worktree)):
        raise Failure(f"{worktree} has a git operation in progress ({', '.join(busy)})")
    current = tree_of(worktree)
    if current != departure_tree:
        raise Failure(f"{worktree} changed since the run left it (tree {current[:12]}, expected {departure_tree[:12]}); "
                      "inspect it before bringing the run back")
    # Everything removed here is preserved in the departure snapshot ref; pi's state stays.
    git(worktree, "reset", "--hard", "-q", head_ref)
    git(worktree, "clean", "-fdq", "-e", f"/{PI_STATE_DIR}")
    apply_range(worktree, "HEAD", snapshot_ref)
    return verify_tree(worktree, expected_tree)


def proc_table():
    table = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        pid = int(entry)
        try:
            with open(f"/proc/{pid}/stat") as handle:
                fields = handle.read().rsplit(")", 1)[1].split()
            with open(f"/proc/{pid}/cmdline", "rb") as handle:
                cmdline = [part.decode(errors="replace") for part in handle.read().split(b"\0") if part]
            with open(f"/proc/{pid}/environ", "rb") as handle:
                agent_id = next((part.split(b"=", 1)[1].decode(errors="replace")
                                 for part in handle.read().split(b"\0") if part.startswith(b"PASEO_AGENT_ID=")), None)
            table[pid] = {"ppid": int(fields[1]), "uid": os.stat(f"/proc/{pid}").st_uid,
                          "cwd": os.path.realpath(f"/proc/{pid}/cwd"), "cmdline": cmdline, "agentId": agent_id}
        except (OSError, IndexError, ValueError):
            continue
    return table


def is_pi_process(cmdline):
    if not cmdline:
        return False
    if os.path.basename(cmdline[0]) in ("pi", ".pi-wrapped"):
        return True
    return any(marker in part for part in cmdline for marker in ("pi-subagents", "pi-coding-agent", "pi-monorepo"))


def within(path, root):
    return path == root or path.startswith(root + os.sep)


def async_runs(session_file):
    """Live pi-subagents async runs owned by an orchestrator session."""
    if not session_file:
        return []
    runs = []
    for status_path in glob.glob(f"/tmp/pi-subagents-uid-{os.getuid()}/async-subagent-runs/*/status.json"):
        try:
            with open(status_path) as handle:
                status = json.load(handle)
        except (OSError, ValueError):
            continue
        if status.get("sessionId") != session_file or status.get("state") not in ("running", "queued"):
            continue
        runs.append({
            "runId": status.get("runId"), "mode": status.get("mode"), "state": status.get("state"), "pid": status.get("pid"),
            "steps": [{key: step.get(key) for key in ("label", "phase", "agent", "status", "workflowKey", "runId", "startedAt")}
                      for step in status.get("steps", [])],
        })
    return runs


def h_inflight(session_file):
    return [{key: value for key, value in item.items() if key != "pid"} for item in async_runs(session_file)]


def h_freeze(worktree, session_file=None, agent_ids=None):
    """SIGSTOP the run's pi processes and their descendants; returns what was stopped."""
    root = os.path.realpath(worktree)
    uid = os.getuid()
    protected = set()
    pid = os.getpid()
    while pid > 1:
        protected.add(pid)
        try:
            with open(f"/proc/{pid}/stat") as handle:
                pid = int(handle.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    runner_pids = {item["pid"] for item in async_runs(session_file) if isinstance(item.get("pid"), int)}
    stopped, detail = [], []
    for _ in range(8):
        table = proc_table()
        roots = {pid for pid, info in table.items()
                 if info["uid"] == uid and (
                     (agent_ids is not None and info.get("agentId") in agent_ids)
                     or (agent_ids is None and within(info["cwd"], root) and is_pi_process(info["cmdline"])))}
        roots |= {pid for pid in runner_pids if pid in table and table[pid]["uid"] == uid}
        targets, queue = set(roots), list(roots)
        while queue:
            parent = queue.pop()
            for child, info in table.items():
                if info["ppid"] == parent and child not in targets:
                    targets.add(child)
                    queue.append(child)
        fresh = sorted(targets - protected - set(stopped))
        if not fresh:
            break
        for target in fresh:
            try:
                os.kill(target, signal.SIGSTOP)
                stopped.append(target)
                detail.append(f"{target} {' '.join(table[target]['cmdline'])[:100]}")
            except ProcessLookupError:
                pass
        time.sleep(0.3)
    return {"pids": stopped, "detail": detail}


def h_thaw(pids):
    for target in pids:
        try:
            os.kill(target, signal.SIGCONT)
        except ProcessLookupError:
            pass
    return True


def h_kill(pids):
    for target in pids:
        try:
            os.kill(target, signal.SIGKILL)
        except ProcessLookupError:
            pass
    deadline = time.time() + 10
    while time.time() < deadline and any(os.path.exists(f"/proc/{target}") for target in pids):
        time.sleep(0.2)
    return [target for target in pids if os.path.exists(f"/proc/{target}")]


def h_rewrite_paths(run_dir, mapping):
    """Point copied briefs, findings, and scripts at this host's paths."""
    pairs = sorted(((old, new) for old, new in mapping.items() if old and new and old != new), key=lambda pair: -len(pair[0]))
    changed = 0
    for directory, _, files in os.walk(run_dir):
        for name in files:
            if not name.endswith(REWRITE_SUFFIXES):
                continue
            path = os.path.join(directory, name)
            try:
                with open(path, encoding="utf-8") as handle:
                    text = handle.read()
            except (UnicodeDecodeError, OSError):
                continue
            updated = text
            for old, new in pairs:
                updated = updated.replace(old, new)
            if updated != text:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(updated)
                changed += 1
    return changed


def h_move_goals_aside(worktree, destination):
    """Archive source-session goals in place after source processes stop.

    Never move the host-local store into transferred files or touch legacy goals.
    The historical helper name and destination argument remain RPC-compatible.
    """
    archived = []
    directory = goal_store()
    for state in h_goal_states(worktree):
        path = os.path.join(directory, state["file"])
        lock = os.path.join(directory, ".locks", state["id"] + ".lock")
        os.makedirs(os.path.dirname(lock), mode=0o700, exist_ok=True)
        for attempt in range(5000):
            try:
                fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                break
            except FileExistsError:
                try:
                    with open(lock, encoding="utf-8") as handle:
                        pid = json.load(handle).get("pid")
                    if isinstance(pid, int) and pid > 0:
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            os.unlink(lock)
                except (OSError, ValueError):
                    pass
                time.sleep(0.002)
        else:
            raise Failure("Goal lock is held by a live writer: " + state["id"])
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump({"pid": os.getpid()}, handle)
            with open(path, encoding="utf-8") as handle:
                goal = json.load(handle)
            if goal.get("archivedAt"):
                continue
            goal["archivedAt"] = goal["updatedAt"] = now_iso()
            goal["revision"] = goal.get("revision", 0) + 1
            goal["history"] = (goal.get("history", []) + [{"at": goal["updatedAt"],
                "event": "host-dispatch-archive", "sessionId": goal.get("ownerSessionId", "")}])[-50:]
            # Keep objectives private while atomically replacing the record.
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(mode="w", dir=directory, prefix=".archive-", delete=False) as handle:
                    temporary = handle.name
                    json.dump(goal, handle, indent=2)
                    handle.write("\n")
                os.replace(temporary, path)
            finally:
                if temporary and os.path.exists(temporary):
                    os.unlink(temporary)
            archived.append(state["id"])
        finally:
            os.unlink(lock)
    return archived


def h_ensure_repo(path, origin=None):
    if os.path.isdir(os.path.join(path, ".git")):
        return {"created": False}
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if origin:
        result = subprocess.run(["git", "clone", "--quiet", origin, path], capture_output=True, text=True)
        if result.returncode == 0:
            return {"created": True, "clonedFrom": origin}
        shutil.rmtree(path, ignore_errors=True)
    run(["git", "init", "--quiet", path])
    return {"created": True, "clonedFrom": None}


def h_branch_worktrees(repo, branch):
    paths, current = [], None
    for line in git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            current = line[len("worktree "):]
        elif line == f"branch refs/heads/{branch}" and current:
            paths.append(current)
    return paths


def goal_store():
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "pi-goal", "goals")


def h_goal_states(worktree):
    """Session goals whose creation cwd or repository root is this worktree."""
    states = []
    target = os.path.realpath(worktree)
    for path in sorted(glob.glob(os.path.join(goal_store(), "*.json"))):
        try:
            with open(path, encoding="utf-8") as handle:
                goal = json.load(handle)
            if goal.get("version") != 1 or goal.get("archivedAt") or goal.get("status") == "complete":
                continue
            if not any(isinstance(goal.get(key), str) and os.path.realpath(goal[key]) == target for key in ("repoRoot", "cwd")):
                continue
            goal_id = goal.get("id", "")
            if not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", goal_id) or os.path.basename(path) != goal_id + ".json":
                continue
            states.append({"file": os.path.basename(path), "id": goal_id, "status": goal.get("status"),
                           "stopReason": goal.get("statusReason"), "ownerSessionId": goal.get("ownerSessionId")})
        except (OSError, ValueError, AttributeError, TypeError):
            continue
    return states


def h_session_guess(worktree):
    encoded = "--" + os.path.realpath(worktree).lstrip("/").replace("/", "-") + "--"
    candidates = glob.glob(os.path.join(os.path.expanduser("~/.pi/agent/sessions"), encoded, "*.jsonl"))
    return max(candidates, key=os.path.getmtime) if candidates else None


def state_root():
    return os.path.expanduser("~/.local/state/workspace-dispatch")


def h_state_path(key):
    # Never use user-provided names as filesystem or Git-ref components.
    key = hashlib.sha256(key.encode()).hexdigest()[:20]
    return os.path.join(state_root(), "records", key + ".json")


def h_directory_tree(worktree):
    """Fingerprint non-Git files, modes and symlinks without following links."""
    digest = hashlib.sha256()
    for directory, dirs, files in os.walk(worktree, followlinks=False):
        if directory == worktree:
            dirs[:] = [name for name in dirs if name != PI_STATE_DIR]
        for name in sorted(dirs + files):
            path = os.path.join(directory, name)
            stat = os.lstat(path)
            digest.update(json.dumps([os.path.relpath(path, worktree), stat.st_mode]).encode())
            if os.path.islink(path):
                digest.update(os.readlink(path).encode())
            elif os.path.isfile(path):
                with open(path, "rb") as handle:
                    while chunk := handle.read(1024 * 1024):
                        digest.update(chunk)
            elif not os.path.isdir(path):
                raise Failure(f"cannot transfer special file {path}")
        dirs.sort()
    return digest.hexdigest()


def h_capture_directory(worktree, key, seq):
    if within(state_root(), os.path.realpath(worktree)):
        raise Failure(f"{worktree} contains dispatcher state; select a narrower workspace directory")
    parent = os.path.join(state_root(), "snapshots", hashlib.sha256(key.encode()).hexdigest()[:20])
    os.makedirs(parent, exist_ok=True)
    path = tempfile.mkdtemp(prefix=f"{seq}-", dir=parent)
    # rsync preserves symlinks and permissions. Never copy live Pi runtime state.
    run(["rsync", "-a", "--exclude=/.pi", worktree + "/", path + "/"])
    return {"directory": path, "tree": h_directory_tree(path), "head": None, "commit": None, "wipStat": ""}


def h_list_runs():
    """Discover all active tabs, grouping tabs sharing a Git root or directory."""
    here = socket.gethostname()
    saved = [h_read_json(path) for path in sorted(glob.glob(os.path.join(state_root(), "records", "*.json")))]
    away = [entry for entry in saved if entry and entry.get("home") == here and entry.get("host") != here]
    workspaces = json.loads(run(["paseo", "workspace", "ls", "--background", "--json"]))
    agents = json.loads(run(["paseo", "ls", "--global", "--background", "--json"]))
    groups = {}
    for row in agents:
        if str(row.get("status", "")).lower() not in ACTIVE:
            continue
        agent = json.loads(run(["paseo", "inspect", row["id"], "--json"]))
        if agent.get("Archived") or str(agent.get("Status", "")).lower() not in ACTIVE:
            continue
        cwd = os.path.realpath(os.path.expanduser(agent["Cwd"]))
        # Inspect supplies absolute paths; list rows abbreviate the home directory.
        workspace = next((item for item in workspaces if os.path.realpath(item["cwd"]) == cwd), None)
        if not workspace:
            workspace = {"workspaceId": "directory-" + hashlib.sha256(cwd.encode()).hexdigest()[:16],
                         "cwd": cwd, "name": os.path.basename(cwd), "background": row.get("background", False)}
        result = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        is_git = result.returncode == 0
        root = os.path.realpath(result.stdout.strip()) if is_git else cwd
        if root not in groups:
            state = next((item for item in saved if item and item.get("worktree") == root
                          and item.get("host") == here), {})
            key = state.get("feature") or workspace["workspaceId"]
            groups[root] = {**state, "version": 2, "feature": key, "name": workspace.get("name") or key,
                            "projectName": workspace.get("project") or state.get("projectName"),
                            "home": state.get("home", here), "host": here, "worktree": root,
                            "workspaceId": workspace["workspaceId"], "background": workspace.get("background", False),
                            "isGit": is_git, "tabs": [], "moves": state.get("moves", []),
                            "runJson": state.get("runJson") or h_state_path(key)}
            entry = groups[root]
            entry["runDir"] = os.path.join(os.path.dirname(entry["runJson"]), "..", "artifacts", key)
            if is_git:
                entry.update(h_worktree_state(root))
                porcelain = git(root, "worktree", "list", "--porcelain").splitlines()
                entry["repoRoot"] = porcelain[0][len("worktree "):]
                entry["origin"] = git(root, "remote", "get-url", "origin", check=False).strip() or None
        entry = groups[root]
        e2e = None
        if is_git:
            for path in glob.glob(os.path.join(entry["gitDir"], "e2e-feature", "*", "run.json")):
                data = h_read_json(path) or {}
                if data.get("orchestratorAgentId") == agent["Id"]:
                    e2e = data
                    break
        e2e_resume = bool(e2e and f"{e2e['feature']}: add plan" in [
            subject for _, subject in h_log_subjects(root, e2e.get("base"))])
        entry["tabs"].append({"agentId": agent["Id"], "name": agent["Name"], "cwd": cwd,
                              "workspaceId": workspace["workspaceId"], "agent": agent, "e2e": e2e,
                              "e2eResume": e2e_resume})
    # An active tab created in a retained workspace while away must not overwrite
    # the record needed to bring its original tabs home.
    for entry in groups.values():
        if any(item["worktree"] == entry["worktree"] for item in away):
            continue
        away.append(entry)
    return away


HELPERS = {name[2:]: value for name, value in dict(globals()).items() if name.startswith("h_") and callable(value)}


# ---------------------------------------------------------------------------
# Hosts and Paseo.
# ---------------------------------------------------------------------------


class Host:
    def __init__(self, name):
        if name not in HOSTS:
            raise Failure(f"unknown host {name}; known: {', '.join(HOSTS)}")
        self.name = name
        self.local = name == socket.gethostname()
        self.ssh = HOSTS[name]["ssh"]
        self.endpoint = HOSTS[name]["paseo"]

    def call(self, helper, **kwargs):
        if self.local:
            return HELPERS[helper](**kwargs)
        payload = base64.b64encode(json.dumps({"helper": helper, "kwargs": kwargs}).encode()).decode()
        with open(os.path.realpath(__file__), "rb") as handle:
            source = handle.read()
        # Stream requests with the source: transcripts can exceed SSH/exec's
        # per-argument size limit even when the overall command is small.
        source = (f"import sys\nsys.argv = ['workspace-dispatch', '_helper', {payload!r}]\n".encode()
                  + source)
        result = subprocess.run(["ssh", *SSH_OPTS, self.ssh, "python3", "-"],
                                input=source, capture_output=True)
        lines = result.stdout.decode(errors="replace").strip().splitlines()
        try:
            reply = json.loads(lines[-1])
        except (IndexError, ValueError):
            raise Failure(f"{self.name}: helper {helper} failed: {result.stderr.decode(errors='replace').strip()}")
        if not reply.get("ok"):
            raise Failure(f"{self.name}: {reply.get('error')}")
        return reply.get("result")

    def paseo(self, *args, parse=True):
        command = ["paseo"] + ([] if self.local else ["--host", self.endpoint]) + list(args)
        # Migration is an operator action: replacements must not become children
        # of the tab invoking the dispatcher, which may itself be archived.
        env = {key: value for key, value in os.environ.items() if key != "PASEO_AGENT_ID"}
        out = run(command, env=env)
        return json.loads(out) if parse else out

    def remote_path(self, path):
        """rsync/git address of a path on this host."""
        return path if self.local else f"{self.ssh}:{path}"


def ensure_project(host, path, name=None):
    project = next((project for project in host.paseo("project", "ls", "--json")
                    if os.path.normpath(project.get("path", "")) == os.path.normpath(path)), None)
    if project is None:
        reply = host.paseo("project", "create", path, "--json")
        project = reply.get("project", reply) if isinstance(reply, dict) else {}
    project_id = project.get("projectId") or project.get("id")
    if not project_id:
        raise Failure(f"unexpected project reply: {project}")
    # Dedicated transfer paths use dispatch IDs; their visible labels should
    # still match the source project, including when reusing a transfer repo.
    if name and project.get("name") != name:
        host.paseo("project", "rename", project_id, name, "--json")
    return project_id


def field(reply, *names):
    """First present field of a Paseo reply, looking one level into a wrapping object."""
    for scope in (reply, *(value for value in reply.values() if isinstance(value, dict))):
        for name in names:
            if scope.get(name):
                return scope[name]
    return None


def wait_running(host, agent_id, timeout=120):
    deadline = time.time() + timeout
    status = None
    while time.time() < deadline:
        info = host.paseo("inspect", agent_id, "--json")
        status = str(info.get("Status", "")).lower()
        if status in ("running", "idle"):
            return info
        if status in ("error", "closed", "failed", "archived"):
            raise Failure(f"agent {agent_id} on {host.name} is {status}")
        time.sleep(2)
    raise Failure(f"agent {agent_id} on {host.name} did not start (last status: {status})")


def rsync(source, destination, *extra):
    run(["rsync", "-a", "-s", "-e", "ssh " + " ".join(SSH_OPTS), *extra, source, destination])


def agent_launch_args(previous, overrides):
    provider = overrides.provider or previous["Provider"]
    model = previous.get("Model")
    if not overrides.provider and model and model != "-":
        provider += f"/{model}"
    thinking = overrides.thinking or previous.get("Thinking")
    return provider, thinking


# ---------------------------------------------------------------------------
# Runs.
# ---------------------------------------------------------------------------


def home_runs(home):
    return [entry for entry in home.call("list_runs") if entry.get("home", HOME) == home.name]


def select(runs, features):
    if not features:
        return runs
    chosen = []
    for name in features:
        matches = [entry for entry in runs if name in (
            entry["feature"], entry.get("name"), entry.get("workspaceId"),
            *(tab.get("e2e", {}).get("feature") for tab in entry.get("tabs", []) if tab.get("e2e")))]
        if len(matches) != 1:
            raise Failure(f"workspace selector {name!r} matches {len(matches)} workspaces; use an ID from status")
        if matches[0] not in chosen:
            chosen.append(matches[0])
    return chosen


def out_blockers(home, entry, include_paused=False):
    """Apply workspace safety checks without requiring an e2e registration or plan."""
    project_names = {entry.get("projectName"), os.path.basename((entry.get("repoRoot") or "").rstrip("/"))}
    denied = project_names & DISPATCH_PROJECT_DENYLIST
    if denied:
        return [f"project {', '.join(sorted(denied))} is on the dispatch denylist"]
    reasons = []
    if not include_paused:
        for goal in home.call("goal_states", worktree=entry["worktree"]):
            if goal.get("status") == "paused":
                reasons.append("goal paused; pass --include-paused only when explicitly requested")
    if entry.get("isGit"):
        state = home.call("worktree_state", worktree=entry["worktree"])
        if state["inProgress"]:
            reasons.append(f"git operation in progress: {', '.join(state['inProgress'])}")
        # Decide the e2e resume mode without making design approval an
        # eligibility condition. Design tabs use the generic history handoff.
        subjects = None
        for tab in entry.get("tabs", []):
            if tab.get("e2e"):
                if subjects is None:
                    subjects = [subject for _, subject in home.call("log_subjects", worktree=entry["worktree"], base=None)]
                tab["e2eResume"] = f"{tab['e2e']['feature']}: add plan" in subjects
    elif within(state_root(), os.path.realpath(entry["worktree"])):
        reasons.append("directory contains dispatcher state; select a narrower workspace directory")
    for tab in entry.get("tabs", []):
        agent = home.paseo("inspect", tab["agentId"], "--json")
        if agent.get("Archived") or str(agent.get("Status", "")).lower() not in ACTIVE:
            reasons.append(f"tab {tab['agentId']} is no longer active")
    return reasons


def fingerprint(host, entry):
    return host.call("tree_of" if entry["isGit"] else "directory_tree", worktree=entry["worktree"])


def transfer_directory(source, path, destination, target, *options):
    rsync(source.remote_path(path.rstrip("/") + "/"), destination.remote_path(target.rstrip("/") + "/"), *options)


def resume_prompt(tab, packet_path, args):
    if args.resume_prompt:
        return args.resume_prompt.format(packet=packet_path)
    if tab.get("e2e") and tab.get("e2eResume", True):
        return f"/skill:e2e-feature resume {packet_path}"
    return (
        f"Continue the task from a workspace moved to this host. First read the handoff JSON at {packet_path} "
        "and the transcript it references. Recover the user's request, decisions, completed work, pending "
        "questions, and next steps from that history, then continue the authorized work. Files already "
        "contain the transferred work. Use the path mapping in the handoff. Other tabs in the workspace "
        "are being resumed separately; continue only this tab's task. Live provider sessions, Pi goals, "
        "and subagent runtime IDs were not transferred: inspect saved artifacts and reconstruct necessary "
        "tracking rather than waiting on old IDs. Preserve any user pause or unanswered approval; the "
        "host move itself does not authorize resuming paused work. If the history shows the task is "
        "complete, report its state without repeating completed actions."
    )


def move(entry, source, destination, args):
    """Transfer files once and resume every active agent tab in the workspace."""
    key = entry["feature"]
    home_entry = args.home_entry
    seq = len(home_entry.get("moves", [])) + 1
    going_home = destination.name == home_entry.get("home", HOME)
    source_worktree = entry["worktree"]
    tabs = entry.get("tabs", [])
    caller = os.environ.get("PASEO_AGENT_ID")
    if caller and any(tab["agentId"] == caller for tab in tabs):
        say(f"skip {key}: current tab {caller} stays here; tabs sharing its workspace stay together")
        return None
    previous_goals = source.call("goal_states", worktree=source_worktree)
    source_run_dir = entry["runDir"]
    repo = (home_entry.get("away") or {}).get("repo")
    transfer_branch = f"workspace-dispatch/{key}"
    log(f"{entry.get('name', key)}: {source.name} -> {destination.name}, {len(tabs)} tabs (move {seq})")

    if going_home:
        destination_worktree = home_entry["worktree"]
        destination_workspace = home_entry["workspaceId"]
        departure = home_entry["moves"][-1]
        if fingerprint(destination, home_entry) != departure["homeTree"]:
            raise Failure(f"{destination_worktree} changed while away; preserve both versions before returning")
        if home_entry["isGit"]:
            state = destination.call("worktree_state", worktree=destination_worktree)
            if state["head"] != departure["homeHead"] or state["branch"] != departure["homeBranch"]:
                raise Failure(f"{destination_worktree} HEAD or branch changed while away")
    else:
        destination_home = destination.call("ping")["home"]
        # Each source workspace has a separate repository: never force-push a
        # working branch into an unrelated checkout in ~/dev on the away host.
        repo = os.path.join(destination_home, ".local/share/workspace-dispatch/repos", key)
        destination_worktree = os.path.join(destination_home, ".local/share/workspace-dispatch/workspaces", key)
    if args.dry_run:
        log(f"{key}: would transfer {source_worktree} and {len(tabs)} tabs to {destination.name}:{destination_worktree}")
        for tab in tabs:
            provider, thinking = agent_launch_args(tab["agent"], args)
            log(f"  {tab['agentId']} {tab['name']} ({provider}, thinking={thinking or 'default'})")
        return None

    # Export through Paseo before SIGSTOP: a live provider may need to service
    # the history RPC. Failure to export must leave the source running.
    transcripts = {tab["agentId"]: source.paseo("logs", tab["agentId"], "--json") for tab in tabs}
    created_workspace = None
    if not going_home:
        if entry["isGit"]:
            destination.call("ensure_repo", path=repo)
            leftovers = destination.call("branch_worktrees", repo=repo, branch=transfer_branch)
            if leftovers:
                raise Failure(f"partial destination worktree exists: {', '.join(leftovers)}; inspect it before retrying")
            project_id = ensure_project(destination, repo, entry.get("projectName"))
        else:
            destination.call("mkdir", path=destination_worktree)
            project_id = ensure_project(destination, destination_worktree, entry.get("projectName"))

    frozen = source.call("freeze", worktree=source_worktree, agent_ids=[tab["agentId"] for tab in tabs])
    launched_tabs = []
    adopted_tree = None
    try:
        snapshot = source.call("snapshot", worktree=source_worktree, feature=key, seq=seq) if entry["isGit"] else source.call(
            "capture_directory", worktree=source_worktree, key=key, seq=seq)
        if entry["isGit"]:
            if going_home:
                incoming = f"{REF_NS}/{key}/incoming-{seq}"
                git(destination_worktree, "fetch", "--quiet", "--no-tags", "--force", source.remote_path(repo),
                    f"{snapshot['headRef']}:{incoming}", f"{snapshot['snapshotRef']}:{snapshot['snapshotRef']}")
            else:
                git(source_worktree, "push", "--quiet", "--no-verify", "--force", destination.remote_path(repo),
                    f"{snapshot['head']}:refs/heads/{transfer_branch}", f"{snapshot['headRef']}:{snapshot['headRef']}",
                    f"{snapshot['snapshotRef']}:{snapshot['snapshotRef']}")
                workspace = destination.paseo("workspace", "create", "--isolation", "worktree", "--mode", "checkout-branch",
                    "--branch", transfer_branch, "--project", project_id, "--title", entry.get("name", key),
                    "--background" if entry.get("background") else "--no-background", "--json")
                created_workspace = field(workspace, "workspaceId", "id")
                destination_worktree = field(workspace, "cwd", "path", "worktreePath")
                destination_workspace = created_workspace
                if not destination_worktree or not created_workspace:
                    raise Failure(f"unexpected workspace create reply: {workspace}")
            destination_git_dir = destination.call("git_dir", worktree=destination_worktree)
            if going_home:
                adopted_tree = snapshot["tree"]
                warnings = destination.call("adopt_incoming", worktree=destination_worktree, head_ref=incoming,
                    snapshot_ref=snapshot["snapshotRef"], expected_tree=snapshot["tree"], departure_tree=departure["homeTree"])
            else:
                warnings = destination.call("apply_snapshot", worktree=destination_worktree,
                    snapshot_ref=snapshot["snapshotRef"], expected_tree=snapshot["tree"])
        else:
            destination_git_dir = None
            # The outgoing snapshot also retains a complete pre-return backup.
            if going_home:
                destination.call("capture_directory", worktree=destination_worktree, key=key + "-return-backup", seq=seq)
            adopted_tree = snapshot["tree"] if going_home else None
            transfer_directory(source, snapshot["directory"], destination, destination_worktree, "--delete", "--exclude=/.pi")
            if destination.call("directory_tree", worktree=destination_worktree) != snapshot["tree"]:
                raise Failure("destination directory differs from the snapshot")
            adopted_tree = snapshot["tree"] if going_home else None
            warnings = []
            if not going_home:
                workspace = destination.paseo("workspace", "create", "--isolation", "local", "--path", destination_worktree,
                    "--project", project_id, "--title", entry.get("name", key), "--background" if entry.get("background") else "--no-background", "--json")
                created_workspace = field(workspace, "workspaceId", "id")
                destination_workspace = created_workspace
                if not created_workspace:
                    raise Failure(f"unexpected workspace create reply: {workspace}")

        destination_record = home_entry["runJson"] if going_home else destination.call("state_path", key=key)
        destination_run_dir = os.path.join(os.path.dirname(destination_record), "..", "artifacts", key)
        destination.call("mkdir", path=destination_run_dir)
        # Preserve earlier handoffs across repeated moves.
        if source.call("read_json", path=entry["runJson"]):
            transfer_directory(source, source_run_dir, destination, destination_run_dir)
        path_mapping = {source_worktree: destination_worktree}
        if entry["isGit"]:
            path_mapping[entry["gitDir"]] = destination_git_dir
        destination.call("rewrite_paths", run_dir=destination_run_dir, mapping=path_mapping)
        for index, tab in enumerate(tabs):
            previous = source.paseo("inspect", tab["agentId"], "--json")
            provider, thinking = agent_launch_args(previous, args)
            transcript = os.path.join(destination_run_dir, f"{seq}-tab-{index}-transcript.json")
            destination.call("write_json", path=transcript, data=transcripts[tab["agentId"]])
            packet_path = os.path.join(destination_run_dir, f"{seq}-tab-{index}.json")
            tab_cwd = os.path.join(destination_worktree, os.path.relpath(tab["cwd"], source_worktree))
            e2e = tab.get("e2e")
            run_dir = destination_run_dir
            inflight = []
            accepted = []
            if e2e:
                run_dir = os.path.join(destination_git_dir, "e2e-feature", e2e["feature"])
                destination.call("mkdir", path=run_dir)
                transfer_directory(source, e2e["runDir"], destination, run_dir, "--exclude=/run.json")
                destination.call("rewrite_paths", run_dir=run_dir, mapping=path_mapping)
                inflight = source.call("inflight", session_file=e2e.get("sessionFile"))
                accepted = [subject for _, subject in source.call("log_subjects", worktree=source_worktree, base=e2e.get("base"))
                            if subject.startswith(e2e["feature"] + ": ")]
                # Seed the registration before launch; a fast resumed agent may
                # register itself immediately. Do not overwrite its sessionFile.
                destination.call("write_json", path=os.path.join(run_dir, "run.json"), data={**e2e,
                    "host": destination.name, "home": home_entry.get("home", HOME), "worktree": destination_worktree,
                    "gitDir": destination_git_dir, "runDir": run_dir, "workspaceId": destination_workspace,
                    "orchestratorAgentId": None, "sessionFile": None, "away": None})
            destination.call("write_json", path=packet_path, data={
                "version": 2, "seq": seq, "feature": e2e["feature"] if e2e else key,
                "from": source.name, "to": destination.name, "home": home_entry.get("home", HOME), "at": now_iso(),
                "branch": snapshot.get("branch"), "base": e2e.get("base") if e2e else None,
                "head": snapshot["head"], "snapshot": snapshot["commit"], "wipStat": snapshot["wipStat"],
                "plan": f"docs/features/{e2e['feature']}-plan.md" if e2e else None,
                "acceptedCommits": accepted, "inFlight": inflight, "worktree": destination_worktree,
                "gitDir": destination_git_dir, "runDir": run_dir, "sourceWorktree": source_worktree,
                "transcript": transcript, "pathMapping": path_mapping, "warnings": warnings,
                "previousOrchestrator": {"host": source.name, "agentId": tab["agentId"], "provider": provider, "thinking": thinking},
                "previousGoals": previous_goals, "previousAgent": previous, "tabs": [item["name"] for item in tabs],
            })
            launch_args = ["run", "--no-wait", "--json", "--provider", provider,
                           "--workspace", destination_workspace, "--cwd", tab_cwd, "--title", tab["name"]]
            if thinking and thinking != "auto":
                launch_args.extend(["--thinking", thinking])
            if previous.get("Mode") and previous["Mode"] != "default":
                launch_args.extend(["--mode", previous["Mode"]])
            launched = destination.paseo(*launch_args, resume_prompt(tab, packet_path, args))
            agent_id = field(launched, "agentId", "id")
            if not agent_id:
                raise Failure(f"unexpected agent launch reply: {launched}")
            new_tab = {**tab, "agentId": agent_id, "cwd": tab_cwd, "workspaceId": destination_workspace}
            launched_tabs.append(new_tab)
            wait_running(destination, agent_id)
            if e2e:
                registration = destination.call("read_json", path=os.path.join(run_dir, "run.json")) or {}
                registration.update(orchestratorAgentId=agent_id)
                destination.call("write_json", path=os.path.join(run_dir, "run.json"), data=registration)
                new_tab["e2e"] = registration
    except BaseException:
        # Stop destination writers before allowing source writers to continue.
        cleanup_failed = False
        for tab in launched_tabs:
            try:
                destination.paseo("archive", "--force", tab["agentId"], "--json", parse=False)
            except Failure as error:
                cleanup_failed = True
                log(f"could not archive replacement {tab['agentId']}: {error}")
        if created_workspace:
            try:
                destination.paseo("workspace", "archive", created_workspace, "--json", parse=False)
                cleanup_failed = False
            except Failure as error:
                log(f"could not archive partial workspace {created_workspace}: {error}")
        if adopted_tree:
            home_entry["moves"][-1]["homeTree"] = fingerprint(destination, home_entry)
            if entry["isGit"]:
                state = destination.call("worktree_state", worktree=home_entry["worktree"])
                home_entry["moves"][-1].update(homeHead=state["head"], homeBranch=state["branch"])
            destination.call("write_json", path=home_entry["runJson"], data=home_entry)
        if cleanup_failed:
            log(f"source remains frozen to avoid two writers; inspect replacements, then thaw PIDs {frozen['pids']}")
        else:
            source.call("thaw", pids=frozen["pids"])
        raise

    record = {"seq": seq, "from": source.name, "to": destination.name, "at": now_iso(),
              "head": snapshot["head"], "snapshot": snapshot["commit"], "tabs": [tab["agentId"] for tab in launched_tabs]}
    here = {**home_entry, "host": destination.name, "worktree": destination_worktree,
            "gitDir": destination_git_dir, "runDir": destination_run_dir, "runJson": destination_record,
            "workspaceId": destination_workspace, "tabs": launched_tabs, "away": None,
            "moves": list(home_entry.get("moves", [])) + [record], "updatedAt": now_iso()}
    if not going_home:
        record.update(homeTree=snapshot["tree"], homeHead=snapshot["head"], homeBranch=snapshot.get("branch"))
        source.call("write_json", path=home_entry["runJson"], data={**home_entry, "host": destination.name,
            "moves": here["moves"], "away": {"host": destination.name, "repo": repo, "worktree": destination_worktree,
            "runDir": destination_run_dir, "runJson": destination_record, "workspaceId": destination_workspace,
            "tabs": launched_tabs}, "updatedAt": now_iso()})
    destination.call("write_json", path=destination_record, data=here)
    # Ownership records now point to the destination; do not thaw after this point.
    survivors = source.call("kill", pids=frozen["pids"])
    if survivors:
        log(f"processes still alive on {source.name}: {survivors}")
    for tab in tabs:
        try:
            source.paseo("archive", "--force", tab["agentId"], "--json", parse=False)
        except Failure as error:
            log(f"could not archive old tab {tab['agentId']}: {error}")
    source.call("move_goals_aside", worktree=source_worktree,
                destination=os.path.join(source_run_dir, f"{seq}-goals-{source.name}"))
    if going_home:
        # This is our dedicated away workspace; all of its agent tabs have moved.
        source.paseo("workspace", "archive", entry["workspaceId"], "--json", parse=False)
        # Local directory workspaces retain their files; keep them as recovery copies.
        source.call("write_json", path=entry["runJson"], data={**entry, "host": destination.name, "tabs": []})
    return [tab["agentId"] for tab in launched_tabs]


# ---------------------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------------------


def require_home():
    if socket.gethostname() != HOME:
        raise Failure(f"run this on {HOME}, the home host")
    # An SSH disconnect must not interrupt a move halfway.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


def forward_back():
    """Run the same dispatcher on home, which drives the existing return protocol."""
    here = socket.gethostname()
    if here not in HOSTS:
        raise Failure(f"run this on {HOME} or a known away host ({', '.join(HOSTS)})")
    home = Host(HOME)
    # Keep a real source file for Host.call(), which streams __file__ to helpers.
    # Check the remote hostname before running to prevent forwarding loops.
    bootstrap = "\n".join([
        "import os, runpy, signal, socket, sys, tempfile",
        f"expected = {HOME!r}",
        "if socket.gethostname() != expected:",
        "    sys.exit(f'e2e-dispatch: expected {expected}, reached {socket.gethostname()}')",
        "signal.signal(signal.SIGHUP, signal.SIG_IGN)",
        f"os.environ.update(E2E_DISPATCH_HOME={HOME!r}, E2E_DISPATCH_AWAY={AWAY!r}, "
        f"PASEO_AGENT_ID={os.environ.get('PASEO_AGENT_ID', '')!r})",
        "with tempfile.TemporaryDirectory(prefix='e2e-dispatch-') as directory:",
        "    path = os.path.join(directory, 'e2e-dispatch.py')",
        "    with open(path, 'wb') as handle:",
        "        handle.write(sys.stdin.buffer.read())",
        "    sys.argv[0] = path",
        "    runpy.run_path(path, run_name='__main__')",
    ])
    command = shlex.join(["python3", "-c", bootstrap, *sys.argv[1:]])
    log(f"forwarding back from {here} to {home.name}; {home.name} must be awake and reachable over SSH")
    with open(os.path.realpath(__file__), "rb") as handle:
        source = handle.read()
    result = subprocess.run(["ssh", *SSH_OPTS, home.ssh, command], input=source)
    sys.exit(result.returncode)


def cmd_status(args):
    here = socket.gethostname()
    host = Host(here)
    entries = home_runs(host) if here == HOME else host.call("list_runs")
    if not entries:
        say(f"No active workspace agent tabs on {here}.")
    for entry in entries:
        where = entry.get("host", here)
        tabs = (entry.get("away") or {}).get("tabs", []) if where != here else entry.get("tabs", [])
        say(f"{entry['feature']}  {entry.get('name', '')}  on {where}  {entry['worktree']}")
        for tab in tabs:
            try:
                info = Host(where).paseo("inspect", tab["agentId"], "--json")
                status = "archived" if info.get("Archived") else info.get("Status", "unknown")
            except Failure:
                status = "unreachable"
            say(f"  {tab['agentId']}  {status}  {tab['name']}")
    # Terminal tabs are deliberately not migrated. Surface them in the inventory.
    for terminal in host.paseo("terminal", "ls", "--json"):
        say(f"terminal (stays on {here}): {terminal.get('id') or terminal.get('terminalId')} {terminal.get('title', '')}")
    if here != HOME:
        say(f"Run workspace-dispatch back here or on {HOME}; {HOME} must be awake.")


def cmd_out(args):
    require_home()
    home, away = Host(HOME), Host(args.to)
    if away.name == home.name:
        raise Failure("destination must differ from the home host")
    away.call("ping")
    candidates = select([entry for entry in home_runs(home) if entry.get("host", home.name) == home.name], args.features)
    if not candidates:
        say(f"Nothing to move: no active workspace tabs on {home.name}")
        return
    failures = 0
    for entry in candidates:
        try:
            reasons = out_blockers(home, entry, args.include_paused)
            if reasons:
                say(f"skip {entry['feature']}: {'; '.join(reasons)}")
                continue
            args.home_entry = entry
            agents = move(entry, home, away, args)
            if agents is not None:
                say(f"moved {entry['feature']} to {away.name}: agents {', '.join(agents) or '(files only)'}")
        except Failure as error:
            failures += 1
            say(f"FAILED {entry['feature']}: {error}")
    sys.exit(1 if failures else 0)


def cmd_back(args):
    if socket.gethostname() != HOME:
        forward_back()
        return
    require_home()
    home = Host(HOME)
    candidates = select([entry for entry in home_runs(home) if entry.get("host", home.name) != home.name], args.features)
    if not candidates:
        say(f"Nothing to bring back: every workspace is on {home.name}")
        return
    failures = 0
    for home_entry in candidates:
        away_info = home_entry.get("away") or {}
        source = Host(away_info.get("host") or home_entry["host"])
        try:
            entry = source.call("read_json", path=away_info["runJson"])
            if not entry:
                raise Failure(f"no dispatch record on {source.name} at {away_info['runJson']}")
            for row in home.paseo("ls", "--global", "--background", "--json"):
                if str(row.get("status", "")).lower() in ACTIVE:
                    agent = home.paseo("inspect", row["id"], "--json")
                    if within(agent["Cwd"], home_entry["worktree"]):
                        raise Failure(f"active home tab {row['id']} uses the retained workspace; stop it before returning")
            # Include tabs opened after dispatch, and do not resume closed tasks.
            live = next((item for item in source.call("list_runs") if item["worktree"] == entry["worktree"]), None)
            entry["tabs"] = live["tabs"] if live else []
            args.home_entry = home_entry
            agents = move(entry, source, home, args)
            if agents is not None:
                say(f"brought {home_entry['feature']} back to {home.name}: agents {', '.join(agents) or '(files only)'}")
        except Failure as error:
            failures += 1
            say(f"FAILED {home_entry['feature']}: {error}")
    sys.exit(1 if failures else 0)



def cmd_register(args):
    """Record the run of the orchestrator calling this, from its own environment."""
    worktree = run(["git", "rev-parse", "--show-toplevel"]).strip()
    directory = git_dir(worktree)
    feature = args.feature
    if not feature:
        existing = glob.glob(os.path.join(directory, "e2e-feature", "*", "run.json"))
        if len(existing) != 1:
            raise Failure("pass --feature <feature>")
        feature = os.path.basename(os.path.dirname(existing[0]))
    run_dir = os.path.join(directory, "e2e-feature", feature)
    path = os.path.join(run_dir, "run.json")
    data = h_read_json(path) or {"version": 1, "moves": []}
    host = socket.gethostname()
    data["feature"] = feature
    data.setdefault("home", args.home or host)
    data["host"] = host
    data.update({"worktree": worktree, "gitDir": directory, "runDir": run_dir,
                 "branch": git(worktree, "branch", "--show-current").strip()})
    worktree_json = h_read_json(os.path.join(directory, "paseo", "worktree.json")) or {}
    data.setdefault("base", worktree_json.get("baseRef") or worktree_json.get("baseRefName"))
    porcelain = git(worktree, "worktree", "list", "--porcelain").splitlines()
    data.setdefault("repoRoot", porcelain[0][len("worktree "):] if porcelain else worktree)
    origin = git(data["repoRoot"], "remote", "get-url", "origin", check=False).strip()
    data.setdefault("origin", origin or None)
    try:
        for workspace in json.loads(run(["paseo", "workspace", "ls", "--json"])):
            if os.path.normpath(workspace.get("cwd", "")) == os.path.normpath(worktree):
                data["workspaceId"] = workspace.get("workspaceId")
    except (Failure, ValueError, FileNotFoundError):
        pass
    if os.environ.get("PASEO_AGENT_ID"):
        data["orchestratorAgentId"] = os.environ["PASEO_AGENT_ID"]
    if os.environ.get("PI_SESSION_FILE"):
        data["sessionFile"] = os.environ["PI_SESSION_FILE"]
    data["updatedAt"] = now_iso()
    h_write_json(path, data)
    print(json.dumps({key: data.get(key) for key in ("feature", "home", "host", "worktree", "branch", "workspaceId",
                                                     "orchestratorAgentId", "sessionFile")}, indent=2))


def cmd_helper(payload):
    try:
        request = json.loads(base64.b64decode(payload))
        result = HELPERS[request["helper"]](**request["kwargs"])
        print(json.dumps({"ok": True, "result": result}))
    except Exception as error:  # reported to the calling host
        print(json.dumps({"ok": False, "error": f"{type(error).__name__}: {error}"}))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "_helper":
        cmd_helper(sys.argv[2])
        return
    parser = argparse.ArgumentParser(prog="workspace-dispatch", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="list active workspace tabs and where they run")
    for name, help_text in (("out", f"move runs from {HOME} to another host"), ("back", f"bring runs back to {HOME}")):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("features", nargs="*", help="workspace IDs, names, or e2e feature names (default: all active tabs)")
        command.add_argument("--dry-run", action="store_true", help="report what would move, change nothing")
        command.add_argument("--resume-prompt", help="prompt for replacement agents; {packet} is each tab's handoff file")
        command.add_argument("--provider", help="provider/model for replacement agents (default: preserve each tab's)")
        command.add_argument("--thinking", help="thinking level for replacement agents (default: preserve each tab's)")
        if name == "out":
            command.add_argument("--to", default=AWAY, help=f"destination host (default: {AWAY})")
            command.add_argument("--include-paused", action="store_true", help="also move runs whose goal is paused")
    register = commands.add_parser("register", help="record the calling orchestrator's run (used by the e2e-feature skill)")
    register.add_argument("--feature")
    register.add_argument("--home", help="host that delivers the run (default: this host)")
    args = parser.parse_args()
    try:
        if args.command in ("out", "back") and socket.gethostname() == HOME and not args.dry_run:
            os.makedirs(state_root(), exist_ok=True)
            with open(os.path.join(state_root(), "transfer.lock"), "w") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise Failure("another workspace transfer is already running")
                {"out": cmd_out, "back": cmd_back}[args.command](args)
        else:
            {"status": cmd_status, "out": cmd_out, "back": cmd_back, "register": cmd_register}[args.command](args)
    except Failure as error:
        print(f"workspace-dispatch: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
