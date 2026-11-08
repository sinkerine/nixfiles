"""Regression checks for forwarding returns without moving any live runs."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("e2e_dispatch", Path(__file__).with_name("e2e-dispatch.py"))
dispatch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dispatch)


class ReturnForwardingTests(unittest.TestCase):
    def forward(self, argv, returncode=0):
        with patch.object(dispatch.socket, "gethostname", return_value="sachi"), \
                patch.object(sys, "argv", ["e2e-dispatch", *argv]), \
                patch.object(dispatch.subprocess, "run", return_value=subprocess.CompletedProcess([], returncode)) as remote, \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as exited:
                dispatch.cmd_back(None)
        self.assertEqual(exited.exception.code, returncode)
        return remote.call_args

    def test_preserves_selection_options_and_source(self):
        argv = ["back", "--dry-run", "hindsight-memory", "stack-quality", "--provider", "pi/model",
                "--thinking", "high", "--resume-prompt", "resume {packet}; $(touch /tmp/unwanted) 'quoted'"]
        call = self.forward(argv)
        self.assertEqual(call.args[0][:-1], ["ssh", *dispatch.SSH_OPTS, "kazuki"])
        remote_command = shlex.split(call.args[0][-1])
        self.assertEqual(remote_command[:2], ["python3", "-c"])
        self.assertEqual(remote_command[3:], argv)
        self.assertEqual(call.kwargs["input"], Path(dispatch.__file__).read_bytes())

    def test_propagates_ssh_failure(self):
        self.forward(["back", "hindsight-memory"], returncode=255)

    def test_home_runs_existing_return_path(self):
        with patch.object(dispatch.socket, "gethostname", return_value="kazuki"), \
                patch.object(dispatch, "forward_back") as forward, \
                patch.object(dispatch, "require_home"), \
                patch.object(dispatch, "home_runs", return_value=[]), \
                contextlib.redirect_stdout(io.StringIO()):
            dispatch.cmd_back(type("Args", (), {"features": []})())
        forward.assert_not_called()

    def test_unknown_host_does_not_connect(self):
        with patch.object(dispatch.socket, "gethostname", return_value="unknown"), \
                patch.object(dispatch.subprocess, "run") as remote:
            with self.assertRaises(dispatch.Failure):
                dispatch.cmd_back(None)
        remote.assert_not_called()

    def test_bootstrap_keeps_source_available_and_cleans_up(self):
        # Execute the actual SSH bootstrap locally with a harmless stand-in dispatcher.
        # Its __file__ must remain readable while running, including after stdin is consumed.
        actual_host = socket.gethostname()
        with patch.object(dispatch, "HOME", actual_host):
            call = self.forward(["back", "--dry-run", "a feature"])
        command = shlex.split(call.args[0][-1])
        source = b"import json, pathlib, sys\nprint(json.dumps([sys.argv, pathlib.Path(__file__).read_text()]))\nsys.exit(7)\n"
        result = subprocess.run(command, input=source, capture_output=True)
        self.assertEqual(result.returncode, 7, result.stderr)
        argv, received = json.loads(result.stdout)
        self.assertEqual(argv[1:], ["back", "--dry-run", "a feature"])
        self.assertEqual(received, source.decode())
        self.assertFalse(Path(argv[0]).exists())


if __name__ == "__main__":
    unittest.main()
