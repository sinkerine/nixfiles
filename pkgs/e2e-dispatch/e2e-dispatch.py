#!/usr/bin/env python3
"""Move a running /skill:e2e-feature run between hosts.

`e2e-dispatch out` runs on the home host (kazuki) before it suspends and moves each active
run to the away host (sachi); `e2e-dispatch back` brings them home. A move:

1. freezes the run's processes (its pi orchestrator, pi-subagents runners, and their
   descendants) with SIGSTOP;
2. snapshots the worktree (commits plus uncommitted and untracked files) as a commit under
   refs/e2e-dispatch/<feature>/;
3. transfers the branch, the snapshot, the run directory, and a copy of the orchestrator
   transcript, then checks that the destination worktree matches the snapshot exactly;
4. starts a fresh orchestrator there in `/skill:e2e-feature resume` mode and waits until
   Paseo reports it running;
5. only then kills the frozen processes, archives the old orchestrator, and moves its goal
   files aside.

A failure before step 5 thaws the source, so the run continues where it was.

The away host's half of each step runs this same file, streamed over SSH, so both hosts
always run one version.

TODO: once this is stable, run `e2e-dispatch out` automatically when kazuki suspends (a
logind delay inhibitor plus a raised InhibitDelayMaxSec) and `e2e-dispatch back` after it
resumes, instead of by hand.
"""

import argparse
import base64
import datetime
import glob
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
HOME = os.environ.get("E2E_DISPATCH_HOME", "kazuki")
AWAY = os.environ.get("E2E_DISPATCH_AWAY", "sachi")
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
        print(f"[e2e-dispatch] {message}", file=sys.stderr, flush=True)
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
    branch = git(worktree, "symbolic-ref", "--short", "HEAD").strip()
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
            table[pid] = {"ppid": int(fields[1]), "uid": os.stat(f"/proc/{pid}").st_uid,
                          "cwd": os.path.realpath(f"/proc/{pid}/cwd"), "cmdline": cmdline}
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


def h_freeze(worktree, session_file=None):
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
                 if info["uid"] == uid and within(info["cwd"], root) and is_pi_process(info["cmdline"])}
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
    source = os.path.join(worktree, ".pi", "goals")
    if not os.path.isdir(source):
        return None
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.move(source, destination)
    return destination


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


def h_goal_states(worktree):
    """Status of each active pi goal in the worktree, as pi-goal-x saved it."""
    states = []
    for path in sorted(glob.glob(os.path.join(worktree, PI_STATE_DIR, "goals", "active_goal_*.md"))):
        try:
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
        except OSError:
            continue
        found = {key: re.search(rf'"{key}"\s*:\s*"([^"]*)"', text) for key in ("status", "stopReason")}
        states.append({"file": os.path.basename(path), **{key: (match.group(1) if match else None) for key, match in found.items()}})
    return states


def h_session_guess(worktree):
    encoded = "--" + os.path.realpath(worktree).lstrip("/").replace("/", "-") + "--"
    candidates = glob.glob(os.path.join(os.path.expanduser("~/.pi/agent/sessions"), encoded, "*.jsonl"))
    return max(candidates, key=os.path.getmtime) if candidates else None


def h_list_runs():
    """Every e2e-feature run recorded in this host's Paseo worktrees."""
    try:
        workspaces = json.loads(run(["paseo", "workspace", "ls", "--json"]))
    except (Failure, ValueError, FileNotFoundError):
        workspaces = []
    found = []
    for workspace in workspaces:
        cwd = workspace.get("cwd")
        if workspace.get("isolation") != "worktree" or not cwd or not os.path.isdir(cwd):
            continue
        try:
            directory = git_dir(cwd)
        except Failure:
            continue
        for path in glob.glob(os.path.join(directory, "e2e-feature", "*", "run.json")):
            data = h_read_json(path) or {}
            data["runJson"] = path
            data.setdefault("workspaceId", workspace.get("workspaceId"))
            found.append(data)
    return found


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
        result = subprocess.run(["ssh", *SSH_OPTS, self.ssh, "python3", "-", "_helper", payload],
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
        out = run(command)
        return json.loads(out) if parse else out

    def remote_path(self, path):
        """rsync/git address of a path on this host."""
        return path if self.local else f"{self.ssh}:{path}"


def ensure_project(host, path):
    for project in host.paseo("project", "ls", "--json"):
        if os.path.normpath(project.get("path", "")) == os.path.normpath(path):
            return project.get("projectId") or project.get("id")
    reply = host.paseo("project", "create", path, "--json")
    project = reply.get("project", reply) if isinstance(reply, dict) else {}
    project_id = project.get("projectId") or project.get("id")
    if not project_id:
        raise Failure(f"unexpected `paseo project create` reply: {reply}")
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
    provider = overrides.provider or f"{previous.get('Provider', 'pi')}/{previous.get('Model', 'magpie/gpt-6.1-sol')}".rstrip("/")
    thinking = overrides.thinking or previous.get("Thinking") or "medium"
    return provider, thinking


# ---------------------------------------------------------------------------
# Runs.
# ---------------------------------------------------------------------------


def home_runs(home):
    return [entry for entry in home.call("list_runs") if entry.get("home", HOME) == home.name]


def select(runs, features):
    if not features:
        return runs
    wanted = set(features)
    chosen = [entry for entry in runs if entry.get("feature") in wanted]
    missing = wanted - {entry.get("feature") for entry in chosen}
    if missing:
        raise Failure(f"no run named {', '.join(sorted(missing))}")
    return chosen


def out_blockers(home, entry, include_paused=False):
    """Reasons a home run cannot move out now, empty when it can."""
    reasons = []
    if not include_paused:
        for goal in home.call("goal_states", worktree=entry["worktree"]):
            if goal.get("status") == "paused":
                reasons.append(f"goal paused by {goal.get('stopReason') or 'someone'}; `/goal-resume` it first or pass --include-paused")
    agent_id = entry.get("orchestratorAgentId")
    if entry.get("host", home.name) != home.name:
        return [f"already on {entry.get('host')}"]
    if not agent_id:
        return ["no orchestrator recorded (run `e2e-dispatch register` in its session)"]
    try:
        agent = home.paseo("inspect", agent_id, "--json")
    except Failure as error:
        return [f"orchestrator {agent_id[:8]} not found: {error}"]
    if agent.get("Archived") or str(agent.get("Status", "")).lower() not in ("running", "idle"):
        reasons.append(f"orchestrator {agent_id[:8]} is {'archived' if agent.get('Archived') else agent.get('Status')}")
    state = home.call("worktree_state", worktree=entry["worktree"])
    if state["inProgress"]:
        reasons.append(f"git operation in progress: {', '.join(state['inProgress'])}")
    subjects = [subject for _, subject in home.call("log_subjects", worktree=entry["worktree"], base=entry.get("base"))]
    if f"{entry['feature']}: add plan" not in subjects:
        reasons.append("plan not approved and committed yet (design phase)")
    for agent_row in home.paseo("ls", "--json"):
        if agent_row.get("cwd") == entry["worktree"] and str(agent_row.get("name", "")).startswith("Design:") \
                and str(agent_row.get("status", "")).lower() not in ("closed", "archived"):
            reasons.append("design tab still open")
    return reasons


def move(entry, source, destination, args):
    """Move one run from `source` to `destination`.

    `entry` is the run's run.json on the source host; `args.home_entry` is its run.json on the
    home host (the same dict when moving out). The home host's worktree stays in place while a
    run is away, so its ignored build state survives; the away host gets a fresh worktree each
    time, archived again when the run comes home.
    """
    feature = entry["feature"]
    home_entry = args.home_entry
    seq = len(home_entry.get("moves", [])) + 1
    going_home = destination.name == home_entry.get("home", HOME)
    source_worktree = entry["worktree"]
    source_git_dir = source.call("git_dir", worktree=source_worktree)
    source_run_dir = os.path.join(source_git_dir, "e2e-feature", feature)
    branch = entry["branch"]
    previous_agent_id = entry.get("orchestratorAgentId")
    previous = source.paseo("inspect", previous_agent_id, "--json") if previous_agent_id else {}
    provider, thinking = agent_launch_args(previous, args)
    session_file = entry.get("sessionFile") or source.call("session_guess", worktree=source_worktree)
    previous_goals = source.call("goal_states", worktree=source_worktree)
    log(f"{feature}: {source.name} -> {destination.name} (move {seq})")

    # Checks and preparation that leave the source untouched.
    if going_home:
        destination_worktree = home_entry["worktree"]
        destination_workspace = home_entry.get("workspaceId")
        departure_tree = home_entry["moves"][-1]["homeTree"]
        repo = home_entry["away"]["repo"]
        current = destination.call("tree_of", worktree=destination_worktree)
        if current != departure_tree:
            raise Failure(f"{destination_worktree} changed since {feature} left it; inspect it before bringing the run back")
        if args.dry_run:
            log(f"{feature}: would freeze it on {source.name}, snapshot it, and continue it in {destination_worktree}")
            return None
    else:
        repo = os.path.join(destination.call("ping")["home"], "dev", os.path.basename(entry["repoRoot"].rstrip("/")))
        if args.dry_run:
            log(f"{feature}: would freeze it, push {branch} to {destination.name}:{repo}, and start {provider} there")
            return None
        created = destination.call("ensure_repo", path=repo, origin=entry.get("origin"))
        if created.get("created"):
            log(f"{feature}: created {destination.name}:{repo}" + (f" from {created['clonedFrom']}" if created.get("clonedFrom") else ""))
        leftovers = destination.call("branch_worktrees", repo=repo, branch=branch)
        if leftovers:
            raise Failure(f"{branch} is already checked out on {destination.name} at {', '.join(leftovers)}; archive that workspace first")
        project_id = ensure_project(destination, repo)

    frozen = source.call("freeze", worktree=source_worktree, session_file=session_file)
    log(f"{feature}: froze {len(frozen['pids'])} processes on {source.name}")
    new_agent_id = None
    created_workspace = None
    adopted_tree = None
    try:
        snapshot = source.call("snapshot", worktree=source_worktree, feature=feature, seq=seq)
        inflight = source.call("inflight", session_file=session_file)
        accepted = [subject for _, subject in source.call("log_subjects", worktree=source_worktree, base=entry.get("base"))
                    if subject.startswith(f"{feature}: ")]

        # Git. The home host drives every transfer, since only it can reach the other over SSH.
        if going_home:
            incoming = f"{REF_NS}/{feature}/incoming-{seq}"
            git(destination_worktree, "fetch", "--quiet", "--no-tags", "--force", source.remote_path(repo),
                f"{snapshot['headRef']}:{incoming}", f"{snapshot['snapshotRef']}:{snapshot['snapshotRef']}")
        else:
            git(source_worktree, "push", "--quiet", "--no-verify", "--force", destination.remote_path(repo),
                f"{snapshot['head']}:refs/heads/{branch}", f"{snapshot['headRef']}:{snapshot['headRef']}",
                f"{snapshot['snapshotRef']}:{snapshot['snapshotRef']}")
            workspace = destination.paseo("workspace", "create", "--isolation", "worktree", "--mode", "checkout-branch",
                                          "--branch", branch, "--project", project_id, "--title", feature, "--json")
            created_workspace = field(workspace, "workspaceId", "id")
            destination_worktree = field(workspace, "cwd", "path", "worktreePath")
            destination_workspace = created_workspace
            if not created_workspace or not destination_worktree:
                raise Failure(f"unexpected `paseo workspace create` reply: {workspace}")

        destination_git_dir = destination.call("git_dir", worktree=destination_worktree)
        destination_run_dir = os.path.join(destination_git_dir, "e2e-feature", feature)
        destination.call("mkdir", path=os.path.join(destination_run_dir, "handoff"))
        # run.json is written only at the commit point below, so a failed move never rewrites it.
        if source.local:
            rsync(source_run_dir + "/", destination.remote_path(destination_run_dir) + "/", "--exclude=/run.json")
        else:
            rsync(source.remote_path(source_run_dir) + "/", destination_run_dir + "/", "--exclude=/run.json")
        transcript = None
        if session_file:
            transcript = os.path.join(destination_run_dir, "handoff", f"{seq}-orchestrator-{source.name}.jsonl")
            if source.local:
                rsync(session_file, destination.remote_path(transcript))
            else:
                rsync(source.remote_path(session_file), transcript)
        destination.call("rewrite_paths", run_dir=destination_run_dir,
                         mapping={source_worktree: destination_worktree, source_git_dir: destination_git_dir})

        if going_home:
            warnings = destination.call("adopt_incoming", worktree=destination_worktree, head_ref=incoming,
                                        snapshot_ref=snapshot["snapshotRef"], expected_tree=snapshot["tree"],
                                        departure_tree=departure_tree)
            adopted_tree = snapshot["tree"]
        else:
            warnings = destination.call("apply_snapshot", worktree=destination_worktree,
                                        snapshot_ref=snapshot["snapshotRef"], expected_tree=snapshot["tree"])
        for warning in warnings:
            log(f"{feature}: {warning}")

        packet_path = os.path.join(destination_run_dir, "handoff", f"{seq}.json")
        destination.call("write_json", path=packet_path, data={
            "version": 1, "seq": seq, "feature": feature, "from": source.name, "to": destination.name,
            "home": home_entry.get("home", HOME), "at": now_iso(), "branch": branch, "base": entry.get("base"),
            "head": snapshot["head"], "snapshot": snapshot["commit"], "wipStat": snapshot["wipStat"],
            "plan": f"docs/features/{feature}-plan.md", "acceptedCommits": accepted, "inFlight": inflight,
            "worktree": destination_worktree, "gitDir": destination_git_dir, "runDir": destination_run_dir,
            "sourceWorktree": source_worktree, "transcript": transcript, "warnings": warnings,
            "previousOrchestrator": {"host": source.name, "agentId": previous_agent_id, "provider": provider, "thinking": thinking},
            "previousGoals": previous_goals,
        })
        prompt = (args.resume_prompt or "/skill:e2e-feature resume {packet}").format(packet=packet_path)
        launched = destination.paseo("run", "--no-wait", "--json", "--provider", provider, "--thinking", thinking,
                                     "--workspace", destination_workspace, "--cwd", destination_worktree,
                                     "--title", f"{feature} · orchestrator on {destination.name}",
                                     "--label", f"e2e-feature={feature}", prompt)
        new_agent_id = field(launched, "agentId", "id")
        if not new_agent_id:
            raise Failure(f"unexpected `paseo run` reply: {launched}")
        wait_running(destination, new_agent_id)
        log(f"{feature}: orchestrator {new_agent_id[:8]} is running on {destination.name}")
    except BaseException:
        source.call("thaw", pids=frozen["pids"])
        log(f"{feature}: move failed; thawed it on {source.name}, where it continues")
        if new_agent_id:
            try:
                destination.paseo("archive", "--force", new_agent_id, "--json", parse=False)
            except Failure as cleanup_error:
                log(f"{feature}: could not archive the new agent {new_agent_id}: {cleanup_error}")
        if created_workspace:
            try:
                destination.paseo("workspace", "archive", created_workspace, "--json", parse=False)
            except Failure as cleanup_error:
                log(f"{feature}: could not archive the partial workspace {created_workspace}: {cleanup_error}")
        if adopted_tree:
            # The home worktree already holds the incoming state; expect that state next time.
            home_entry["moves"][-1]["homeTree"] = adopted_tree
            destination.call("write_json", path=home_entry["runJson"],
                             data={key: value for key, value in home_entry.items() if key != "runJson"})
        raise

    # Commit point: the destination owns the run from here on.
    survivors = source.call("kill", pids=frozen["pids"])
    if survivors:
        log(f"{feature}: processes still alive on {source.name}: {survivors}")
    if previous_agent_id:
        try:
            source.paseo("archive", "--force", previous_agent_id, "--json", parse=False)
        except Failure as error:
            log(f"{feature}: could not archive {previous_agent_id}: {error}")
    record = {"seq": seq, "from": source.name, "to": destination.name, "at": now_iso(), "head": snapshot["head"],
              "snapshot": snapshot["commit"], "fromAgentId": previous_agent_id, "toAgentId": new_agent_id,
              "toWorkspaceId": destination_workspace, "warnings": warnings}
    moves = list(home_entry.get("moves", [])) + [record]
    base_entry = {key: value for key, value in home_entry.items() if key != "runJson"}
    here = {"host": destination.name, "worktree": destination_worktree, "gitDir": destination_git_dir,
            "runDir": destination_run_dir, "workspaceId": destination_workspace, "orchestratorAgentId": new_agent_id,
            "sessionFile": None, "away": None, "moves": moves, "updatedAt": now_iso()}
    if going_home:
        try:
            source.paseo("workspace", "archive", entry["workspaceId"], "--json", parse=False)
        except Failure as error:
            log(f"{feature}: could not archive the {source.name} workspace {entry.get('workspaceId')}: {error}")
        destination.call("write_json", path=os.path.join(destination_run_dir, "run.json"), data={**base_entry, **here})
    else:
        source.call("move_goals_aside", worktree=source_worktree,
                    destination=os.path.join(source_run_dir, "handoff", f"{seq}-goals-{source.name}"))
        record["homeTree"] = snapshot["tree"]
        destination.call("write_json", path=os.path.join(destination_run_dir, "run.json"), data={**base_entry, **here})
        source.call("write_json", path=os.path.join(source_run_dir, "run.json"), data={
            **base_entry, "host": destination.name, "orchestratorAgentId": None, "sessionFile": None, "moves": moves,
            "updatedAt": now_iso(),
            "away": {"host": destination.name, "repo": repo, "worktree": destination_worktree, "gitDir": destination_git_dir,
                     "runDir": destination_run_dir, "workspaceId": destination_workspace, "agentId": new_agent_id},
        })
    log(f"{feature}: done; it continues on {destination.name} as agent {new_agent_id}")
    return new_agent_id


# ---------------------------------------------------------------------------
# Commands.
# ---------------------------------------------------------------------------


def require_home():
    if socket.gethostname() != HOME:
        raise Failure(f"run this on {HOME}, the home host")
    # A move kills the source orchestrator, which may be the process that started this command
    # (for example over SSH). Losing that session must not interrupt the move halfway.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)


def cmd_status(args):
    here = socket.gethostname()
    if here != HOME:
        # The away host cannot reach the home host, so it reports only its own runs.
        runs = HELPERS["list_runs"]()
        if not runs:
            print(f"No e2e-feature runs on {here}.")
            return
        print(f"{'FEATURE':24} {'ORCHESTRATOR':22} WORKTREE ON {here.upper()}")
        for entry in runs:
            agent = entry.get("orchestratorAgentId")
            status = "-"
            if agent:
                try:
                    info = json.loads(run(["paseo", "inspect", agent, "--json"]))
                    status = "archived" if info.get("Archived") else str(info.get("Status"))
                except (Failure, ValueError):
                    status = "unknown"
            print(f"{entry.get('feature', '?'):24} {(agent or '-')[:8] + ' ' + status:22} {entry.get('worktree', '')}")
        print(f"Run `e2e-dispatch back` on {HOME} to bring runs home.")
        return
    home = Host(HOME)
    rows = []
    for entry in home_runs(home):
        where = entry.get("host", home.name)
        agent = (entry.get("away") or {}).get("agentId") if where != home.name else entry.get("orchestratorAgentId")
        host = Host(where)
        status = "-"
        if agent:
            try:
                info = host.paseo("inspect", agent, "--json")
                status = "archived" if info.get("Archived") else str(info.get("Status"))
            except Failure:
                status = "unknown"
        rows.append((entry.get("feature", "?"), where, f"{agent[:8] if agent else '-'} {status}", entry.get("worktree", "")))
    if not rows:
        print("No e2e-feature runs registered on", home.name)
        return
    print(f"{'FEATURE':24} {'ON':8} {'ORCHESTRATOR':22} WORKTREE ON {home.name.upper()}")
    for feature, where, agent, worktree in rows:
        print(f"{feature:24} {where:8} {agent:22} {worktree}")


def cmd_out(args):
    require_home()
    home, away = Host(HOME), Host(args.to)
    away.call("ping")
    candidates = select([entry for entry in home_runs(home) if entry.get("host", home.name) == home.name], args.features)
    if not candidates:
        say(f"Nothing to move: no active runs on {home.name}")
        return
    failures = 0
    for entry in candidates:
        reasons = out_blockers(home, entry, args.include_paused)
        if reasons:
            say(f"skip {entry['feature']}: {'; '.join(reasons)}")
            continue
        try:
            args.home_entry = entry
            agent = move(entry, home, away, args)
            if agent:
                say(f"moved {entry['feature']} to {away.name}: agent {agent}")
        except Failure as error:
            failures += 1
            say(f"FAILED {entry['feature']}: {error}")
    sys.exit(1 if failures else 0)


def cmd_back(args):
    require_home()
    home = Host(HOME)
    candidates = select([entry for entry in home_runs(home) if entry.get("host", home.name) != home.name], args.features)
    if not candidates:
        say(f"Nothing to bring back: every run is on {home.name}")
        return
    failures = 0
    for home_entry in candidates:
        away_info = home_entry.get("away") or {}
        source = Host(away_info.get("host") or home_entry["host"])
        try:
            entry = source.call("read_json", path=os.path.join(away_info["runDir"], "run.json"))
            if not entry:
                raise Failure(f"no run.json on {source.name} at {away_info.get('runDir')}")
            entry["orchestratorAgentId"] = entry.get("orchestratorAgentId") or away_info.get("agentId")
            args.home_entry = home_entry
            agent = move(entry, source, home, args)
            if agent:
                say(f"brought {home_entry['feature']} back to {home.name}: agent {agent}")
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
    parser = argparse.ArgumentParser(prog="e2e-dispatch", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status", help="list e2e-feature runs and where they run")
    for name, help_text in (("out", f"move runs from {HOME} to another host"), ("back", f"bring runs back to {HOME}")):
        command = commands.add_parser(name, help=help_text)
        command.add_argument("features", nargs="*", help="run names (default: every eligible run)")
        command.add_argument("--dry-run", action="store_true", help="report what would move, change nothing")
        command.add_argument("--resume-prompt", help="prompt for the new orchestrator; {packet} is the handoff file")
        command.add_argument("--provider", help="provider/model for the new orchestrator (default: the previous one's)")
        command.add_argument("--thinking", help="thinking level for the new orchestrator (default: the previous one's)")
        if name == "out":
            command.add_argument("--to", default=AWAY, help=f"destination host (default: {AWAY})")
            command.add_argument("--include-paused", action="store_true", help="also move runs whose goal is paused")
    register = commands.add_parser("register", help="record the calling orchestrator's run (used by the e2e-feature skill)")
    register.add_argument("--feature")
    register.add_argument("--home", help="host that delivers the run (default: this host)")
    args = parser.parse_args()
    try:
        {"status": cmd_status, "out": cmd_out, "back": cmd_back, "register": cmd_register}[args.command](args)
    except Failure as error:
        print(f"e2e-dispatch: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
