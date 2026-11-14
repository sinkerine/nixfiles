"""Exercise transfers with real Git/rsync and isolated Paseo/process doubles.

No live agent, SSH connection, or user workspace is mutated by these tests.
"""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("workspace_dispatch", Path(__file__).with_name("e2e-dispatch.py"))
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)


class LocalHost:
    """Two directories stand in for hosts; only process/Paseo operations are fake."""
    def __init__(self, name, root, events):
        self.name = name
        self.root = root
        self.local = True
        self.events = events
        self.agents = {}
        self.projects = {}
        self.project_names = {}
        self.workspaces = {}
        self.workspace_titles = {}
        self.launches = []
        self.fail_launch = None
        self.fail_archive = False

    def call(self, helper, **kwargs):
        self.events.append((self.name, helper))
        if helper == "ping":
            return {"host": self.name, "home": str(self.root)}
        if helper == "freeze":
            return {"pids": [123], "detail": []}
        if helper in ("kill", "thaw"):
            return []
        with patch.object(dispatch, "state_root", return_value=str(self.root / "state")):
            return dispatch.HELPERS[helper](**kwargs)

    def remote_path(self, path):
        return path

    def paseo(self, *args, parse=True):
        self.events.append((self.name, "paseo:" + args[0]))
        if args[0] == "inspect":
            return copy.deepcopy(self.agents[args[1]])
        if args[0] == "logs":
            return {"agentId": args[1], "items": [{"type": "user_message", "text": "Finish the task"}]}
        if args[:2] == ("project", "ls"):
            return [{"projectId": key, "path": value, "name": self.project_names.get(key)}
                    for key, value in self.projects.items()]
        if args[:2] == ("project", "create"):
            self.projects["project"] = args[2]
            return {"projectId": "project"}
        if args[:2] == ("project", "rename"):
            self.project_names[args[2]] = args[3]
            return {"projectId": args[2], "name": args[3]}
        if args[:2] == ("workspace", "create"):
            if args[args.index("--isolation") + 1] == "worktree":
                cwd = str(self.root / "worktree")
                repo = self.projects[args[args.index("--project") + 1]]
                dispatch.git(repo, "worktree", "add", "--quiet", cwd, args[args.index("--branch") + 1])
            else:
                cwd = args[args.index("--path") + 1]
            self.workspaces["away-workspace"] = cwd
            self.workspace_titles["away-workspace"] = args[args.index("--title") + 1]
            return {"workspaceId": "away-workspace", "cwd": cwd}
        if args[:2] == ("workspace", "archive"):
            if self.fail_archive:
                raise dispatch.Failure("archive unavailable")
            cwd = self.workspaces[args[2]]
            if (Path(cwd) / ".git").is_file():
                dispatch.git(cwd, "worktree", "remove", "--force", cwd)
            return {}
        if args[0] == "run":
            self.launches.append(args)
            if len(self.launches) == self.fail_launch:
                raise dispatch.Failure("launch unavailable")
            agent_id = f"{self.name}-agent-{len(self.launches)}"
            self.agents[agent_id] = {
                "Id": agent_id, "Name": args[args.index("--title") + 1],
                "Provider": "pi", "Model": "test-model", "Thinking": "high", "Mode": "default",
                "Status": "running", "Archived": False, "Cwd": args[args.index("--cwd") + 1],
            }
            return {"agentId": agent_id}
        if args[0] == "archive":
            if self.fail_archive:
                raise dispatch.Failure("archive unavailable")
            self.agents[args[2]]["Archived"] = True
            return {}
        raise AssertionError(args)


class SessionGoalTests(unittest.TestCase):
    def test_new_store_detection_and_archive_leave_legacy_untouched(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            worktree = root / "worktree"
            legacy = worktree / ".pi" / "goals"
            legacy.mkdir(parents=True)
            (legacy / "old.md").write_text('"status": "paused"')
            directory = root / "state" / "pi-goal" / "goals"
            directory.mkdir(parents=True)
            def save(goal_id, **values):
                goal = {"version": 1, "id": goal_id, "status": "active", "repoRoot": str(worktree),
                        "cwd": str(worktree / "subdir"), "ownerSessionId": "A", "revision": 1, "history": []}
                goal.update(values)
                (directory / (goal_id + ".json")).write_text(json.dumps(goal))
            save("paused", status="paused", statusReason="user pause")
            save("cwdmatch", repoRoot=str(root / "other"), cwd=str(worktree))
            save("other", repoRoot=str(root / "other"), cwd=str(root / "other"))
            save("archived", archivedAt="yesterday")
            save("complete", status="complete")
            (directory / "invalid.json").write_text("broken")
            with patch.dict(os.environ, {"XDG_STATE_HOME": str(root / "state")}):
                states = dispatch.h_goal_states(str(worktree))
                self.assertEqual({g["id"] for g in states}, {"paused", "cwdmatch"})
                paused = next(g for g in states if g["id"] == "paused")
                self.assertEqual((paused["status"], paused["stopReason"], paused["ownerSessionId"]), ("paused", "user pause", "A"))
                self.assertEqual(set(dispatch.h_move_goals_aside(str(worktree), str(root / "unused"))), {"paused", "cwdmatch"})
                self.assertEqual(dispatch.h_goal_states(str(worktree)), [])
            archived = json.loads((directory / "paused.json").read_text())
            self.assertEqual(archived["status"], "paused")
            self.assertEqual((directory / "paused.json").stat().st_mode & 0o777, 0o600)
            self.assertEqual(archived["revision"], 2)
            self.assertIn("archivedAt", archived)
            self.assertNotIn("archivedAt", json.loads((directory / "other.json").read_text()))
            self.assertTrue((legacy / "old.md").exists())
            self.assertFalse((root / "unused").exists(), "goal records must not enter transferred files")


class RemoteHelperTests(unittest.TestCase):
    def test_large_transcript_streamed_over_stdin(self):
        host = dispatch.Host("sachi")
        host.local = False
        real_run = dispatch.subprocess.run

        def remote_python(command, **kwargs):
            self.assertEqual(command[-2:], ["python3", "-"])
            self.assertLess(max(map(len, command)), 1024)
            return real_run(["python3", "-"], **kwargs)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "transcript.json"
            transcript = {"text": "x" * 200_000}
            with patch.object(dispatch.subprocess, "run", side_effect=remote_python):
                host.call("write_json", path=str(path), data=transcript)
            self.assertEqual(json.loads(path.read_text()), transcript)


class WorkspaceTransferTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.events = []
        self.home = LocalHost("kazuki", self.root / "home", self.events)
        self.away = LocalHost("sachi", self.root / "away", self.events)
        self.home.root.mkdir()
        self.away.root.mkdir()
        self.worktree = self.home.root / "checkout"
        self.worktree.mkdir()
        dispatch.git(str(self.worktree), "init", "--quiet", "-b", "main")
        dispatch.git(str(self.worktree), "config", "user.email", "test@example.invalid")
        dispatch.git(str(self.worktree), "config", "user.name", "Test")
        (self.worktree / "tracked").write_text("original\n")
        (self.worktree / ".gitignore").write_text("ignored\n.pi/\n")
        dispatch.git(str(self.worktree), "add", ".")
        dispatch.git(str(self.worktree), "commit", "--quiet", "-m", "initial")
        (self.worktree / "tracked").write_text("uncommitted\n")
        (self.worktree / "new").write_bytes(b"binary\x00file")
        (self.worktree / "ignored").write_text("host-local")
        self.entry = {
            "feature": "workspace-test", "name": "Ordinary work", "projectName": "Original project",
            "home": "kazuki", "host": "kazuki",
            "worktree": str(self.worktree), "workspaceId": "home-workspace", "background": False,
            "isGit": True, "gitDir": dispatch.git_dir(str(self.worktree)), "moves": [], "tabs": [],
            "runJson": self.home.call("state_path", key="workspace-test"),
        }
        self.entry["runDir"] = str(self.home.root / "state/artifacts/workspace-test")
        for index, provider in enumerate(("pi", "codex")):
            agent_id = f"original-{index}"
            previous = {"Id": agent_id, "Name": f"Tab {index}", "Provider": provider, "Model": f"model-{index}",
                        "Thinking": "high" if index == 0 else "auto", "Mode": "default" if index == 0 else "full-access",
                        "Status": "running", "Archived": False, "Cwd": str(self.worktree)}
            self.home.agents[agent_id] = previous
            self.entry["tabs"].append({"agentId": agent_id, "name": previous["Name"], "cwd": str(self.worktree),
                                       "workspaceId": "home-workspace", "agent": previous, "e2e": None})
        self.args = SimpleNamespace(home_entry=self.entry, dry_run=False, provider=None, thinking=None, resume_prompt=None)
        # commit-tree also runs on the away host. Use a test identity without
        # reading or changing the developer's Git configuration.
        self.env = patch.dict(os.environ, {"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
                                          "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def outgoing(self):
        return dispatch.move(self.entry, self.home, self.away, self.args)

    def test_current_tab_workspace_is_skipped_before_any_transfer(self):
        for dry_run in (False, True):
            for going_home in (False, True):
                with self.subTest(dry_run=dry_run, going_home=going_home):
                    self.args.dry_run = dry_run
                    source, destination = (self.away, self.home) if going_home else (self.home, self.away)
                    before = list(self.events)
                    with patch.dict(os.environ, {"PASEO_AGENT_ID": "original-0"}), \
                            patch.object(dispatch, "say") as output:
                        self.assertIsNone(dispatch.move(self.entry, source, destination, self.args))
                    self.assertEqual(self.events, before)
                    self.assertIn("current tab original-0", output.call_args.args[0])
                    self.assertFalse(self.home.agents["original-1"]["Archived"])

    def test_other_workspace_still_moves_with_current_tab_excluded(self):
        with patch.dict(os.environ, {"PASEO_AGENT_ID": "caller-in-another-workspace"}):
            self.assertEqual(len(self.outgoing()), 2)

    def test_forwarded_return_preserves_current_tab_identity(self):
        import runpy
        import shlex

        with patch.dict(os.environ, {"PASEO_AGENT_ID": "away-caller"}), \
                patch.object(dispatch.socket, "gethostname", return_value="sachi"), \
                patch.object(dispatch.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as remote:
            with self.assertRaises(SystemExit) as exited:
                dispatch.forward_back()
        self.assertEqual(exited.exception.code, 0)
        bootstrap = shlex.split(remote.call_args.args[0][-1])[2]
        with patch.dict(os.environ, {"PASEO_AGENT_ID": "unrelated-home-value"}), \
                patch.object(dispatch.socket, "gethostname", return_value="kazuki"), \
                patch.object(dispatch.sys, "stdin") as stdin, \
                patch.object(dispatch.sys, "argv", ["dispatcher", "back"]), \
                patch.object(runpy, "run_path"):
            stdin.buffer.read.return_value = b""
            exec(bootstrap, {})
            self.assertEqual(os.environ["PASEO_AGENT_ID"], "away-caller")

    def test_transfer_preserves_project_and_workspace_names(self):
        self.outgoing()
        self.assertEqual(self.away.project_names["project"], "Original project")
        self.assertEqual(self.away.workspace_titles["away-workspace"], "Ordinary work")

    def test_directory_transfer_preserves_project_and_workspace_names(self):
        self.entry["isGit"] = False
        self.outgoing()
        self.assertEqual(self.away.project_names["project"], "Original project")
        self.assertEqual(self.away.workspace_titles["away-workspace"], "Ordinary work")

    def test_reused_transfer_project_gets_source_name(self):
        path = str(self.away.root / "repos/workspace-test")
        self.away.projects["existing"] = path
        self.away.project_names["existing"] = "workspace-test"
        self.assertEqual(dispatch.ensure_project(self.away, path, "Original project"), "existing")
        self.assertEqual(self.away.project_names["existing"], "Original project")
        self.assertEqual(list(self.away.projects), ["existing"])

    def test_multiple_tabs_dirty_local_checkout_and_return(self):
        original_tree = dispatch.tree_of(str(self.worktree))
        agents = self.outgoing()
        self.assertEqual(len(agents), 2)
        home_record = dispatch.h_read_json(self.entry["runJson"])
        away_record = dispatch.h_read_json(home_record["away"]["runJson"])
        away_path = Path(away_record["worktree"])
        self.assertEqual(dispatch.tree_of(str(away_path)), original_tree)
        self.assertFalse((away_path / "ignored").exists())
        self.assertTrue(all(agent["Archived"] for agent in self.home.agents.values()))
        self.assertIn("pi/model-0", self.away.launches[0])
        self.assertIn("codex/model-1", self.away.launches[1])
        self.assertIn("full-access", self.away.launches[1])
        self.assertNotIn("--thinking", self.away.launches[1])
        for index in range(2):
            packet = dispatch.h_read_json(str(Path(away_record["runDir"]) / f"1-tab-{index}.json"))
            self.assertEqual(dispatch.h_read_json(packet["transcript"])["items"][0]["text"], "Finish the task")
            self.assertIn("Continue the task", self.away.launches[index][-1])
        (away_path / "tracked").write_text("away work\n")
        dispatch.git(str(away_path), "add", "tracked")
        dispatch.git(str(away_path), "commit", "--quiet", "-m", "away change")
        (away_path / "new").write_text("updated untracked")
        expected = dispatch.tree_of(str(away_path))
        self.args.home_entry = home_record
        returned = dispatch.move(away_record, self.away, self.home, self.args)
        self.assertEqual(len(returned), 2)
        self.assertEqual(dispatch.tree_of(str(self.worktree)), expected)
        self.assertEqual(dispatch.git(str(self.worktree), "branch", "--show-current").strip(), "main")
        self.assertEqual((self.worktree / "ignored").read_text(), "host-local")
        self.assertFalse(away_path.exists())
        self.assertEqual(dispatch.h_read_json(self.entry["runJson"])["host"], "kazuki")

    def test_return_refuses_changed_home_before_freezing(self):
        self.outgoing()
        home_record = dispatch.h_read_json(self.entry["runJson"])
        away_record = dispatch.h_read_json(home_record["away"]["runJson"])
        (self.worktree / "tracked").write_text("new home work")
        self.events.clear()
        self.args.home_entry = home_record
        with self.assertRaisesRegex(dispatch.Failure, "changed while away"):
            dispatch.move(away_record, self.away, self.home, self.args)
        self.assertNotIn(("sachi", "freeze"), self.events)
        self.assertEqual((self.worktree / "tracked").read_text(), "new home work")

    def test_failed_second_launch_archives_destination_before_thaw(self):
        self.away.fail_launch = 2
        with self.assertRaisesRegex(dispatch.Failure, "launch unavailable"):
            self.outgoing()
        archive = self.events.index(("sachi", "paseo:archive"))
        thaw = self.events.index(("kazuki", "thaw"))
        self.assertLess(archive, thaw)
        self.assertNotIn(("kazuki", "kill"), self.events)
        self.assertTrue(all(not agent["Archived"] for agent in self.home.agents.values()))
        self.assertFalse(Path(self.entry["runJson"]).exists())

    def test_failed_cleanup_leaves_source_frozen(self):
        self.away.fail_launch = 2
        self.away.fail_archive = True
        with self.assertRaises(dispatch.Failure):
            self.outgoing()
        self.assertNotIn(("kazuki", "thaw"), self.events)
        self.assertNotIn(("kazuki", "kill"), self.events)

    def test_preview_never_freezes_or_exports_or_creates_files(self):
        self.args.dry_run = True
        self.assertIsNone(self.outgoing())
        self.assertNotIn(("kazuki", "freeze"), self.events)
        self.assertNotIn(("kazuki", "paseo:logs"), self.events)
        self.assertFalse((self.away.root / ".local").exists())
        self.assertFalse(Path(self.entry["runJson"]).exists())

    def test_non_git_directory_round_trip(self):
        dispatch.run(["rm", "-rf", str(self.worktree / ".git")])
        self.entry["isGit"] = False
        self.entry.pop("gitDir")
        (self.worktree / ".pi").mkdir()
        (self.worktree / ".pi/state").write_text("host runtime")
        os.symlink("tracked", self.worktree / "link")
        self.outgoing()
        home_record = dispatch.h_read_json(self.entry["runJson"])
        away_record = dispatch.h_read_json(home_record["away"]["runJson"])
        away_path = Path(away_record["worktree"])
        self.assertTrue((away_path / "link").is_symlink())
        self.assertFalse((away_path / ".pi").exists())
        (away_path / "tracked").write_text("directory update")
        (away_path / "new").unlink()
        self.args.home_entry = home_record
        dispatch.move(away_record, self.away, self.home, self.args)
        self.assertEqual((self.worktree / "tracked").read_text(), "directory update")
        self.assertFalse((self.worktree / "new").exists())
        self.assertEqual((self.worktree / ".pi/state").read_text(), "host runtime")

    def test_registered_e2e_tab_keeps_artifacts_and_resume_contract(self):
        run_dir = Path(self.entry["gitDir"]) / "e2e-feature/feature"
        run_dir.mkdir(parents=True)
        (run_dir / "brief.md").write_text(str(self.worktree))
        self.entry["tabs"][0]["e2e"] = {"feature": "feature", "runDir": str(run_dir), "home": "kazuki"}
        self.outgoing()
        self.assertTrue(self.away.launches[0][-1].startswith("/skill:e2e-feature resume "))
        packet = dispatch.h_read_json(self.away.launches[0][-1].split(" resume ", 1)[1])
        self.assertEqual(packet["feature"], "feature")
        self.assertEqual((Path(packet["runDir"]) / "brief.md").read_text(), packet["worktree"])
        self.assertEqual(dispatch.h_read_json(str(Path(packet["runDir"]) / "run.json"))["orchestratorAgentId"], "sachi-agent-1")
        self.assertIn("Continue the task", self.away.launches[1][-1])

    def test_inventory_groups_unregistered_tabs_and_excludes_closed_tabs(self):
        real_run = dispatch.run
        workspaces = [{"workspaceId": "workspace", "name": "Local checkout", "project": "Original project", "cwd": str(self.worktree),
                       "isolation": "local", "background": True}]
        rows = [{"id": agent_id, "status": "running", "cwd": "~/abbreviated"} for agent_id in self.home.agents]
        rows.append({"id": "closed", "status": "closed"})

        def command(args, **kwargs):
            if args[:3] == ["paseo", "workspace", "ls"]:
                self.assertIn("--background", args)
                return json.dumps(workspaces)
            if args[:2] == ["paseo", "ls"]:
                self.assertIn("--global", args)
                return json.dumps(rows)
            if args[:2] == ["paseo", "inspect"]:
                return json.dumps(self.home.agents[args[2]])
            return real_run(args, **kwargs)

        with patch.object(dispatch, "run", side_effect=command), \
                patch.object(dispatch, "state_root", return_value=str(self.home.root / "state")), \
                patch.object(dispatch.socket, "gethostname", return_value="kazuki"):
            entries = dispatch.h_list_runs()
        self.assertEqual(len(entries), 1)
        self.assertEqual(len(entries[0]["tabs"]), 2)
        self.assertEqual(entries[0]["projectName"], "Original project")
        self.assertEqual(entries[0]["name"], "Local checkout")
        self.assertTrue(entries[0]["background"])
        self.assertTrue(entries[0]["isGit"])


if __name__ == "__main__":
    unittest.main()
