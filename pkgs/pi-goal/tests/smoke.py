#!/usr/bin/env python3
"""Drive real Pi RPC against an isolated, deterministic local model endpoint.

No user config, auth, sessions, legacy goals or remote model services are used.
Run: python3 pkgs/pi-goal/tests/smoke.py
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time


class Model(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        def chunk(delta, finish=None):
            data = {"id": "smoke", "object": "chat.completion.chunk", "created": 1, "model": "smoke",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: " + json.dumps(data) + "\n\n").encode())
            self.wfile.flush()
        try:
            chunk({"role": "assistant", "content": "Smoke progress."})
            time.sleep(0.25)
            chunk({}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class Pi:
    def __init__(self, command, cwd, env):
        self.proc = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.events = queue.Queue()
        self.all = []
        self.errors = []
        def reader():
            for line in self.proc.stdout:
                try:
                    item = json.loads(line)
                    self.all.append(item)
                    self.events.put(item)
                except ValueError:
                    self.errors.append(line)
        def stderr():
            self.errors.extend(self.proc.stderr.readlines())
        threading.Thread(target=reader, daemon=True).start()
        threading.Thread(target=stderr, daemon=True).start()
        self.next_id = 0

    def wait(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            if predicate(event):
                return event
        raise AssertionError(f"Pi event timeout; recent={self.all[-8:]}, stderr={self.errors}")

    def command(self, kind, **args):
        self.next_id += 1
        request_id = str(self.next_id)
        self.proc.stdin.write(json.dumps({"id": request_id, "type": kind, **args}) + "\n")
        self.proc.stdin.flush()
        result = self.wait(lambda e: e.get("type") == "response" and e.get("id") == request_id)
        assert result["success"], result
        return result.get("data")

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            self.proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--adapter", type=Path, help="Optional Paseo pi-goal adapter index.ts for real producer compatibility")
    parser.add_argument("--extension", type=Path, help="Test an installed package's extensions/index.ts")
    args = parser.parse_args()
    snapshots = []
    extension = args.extension or Path(__file__).resolve().parents[1] / "extensions" / "index.ts"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="pi-goal-smoke-") as temporary:
        root = Path(temporary)
        repo = root / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        config = root / "config"
        config.mkdir()
        (config / "models.json").write_text(json.dumps({"providers": {"smoke": {
            "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "api": "openai-completions", "apiKey": "smoke-only",
            "models": [{"id": "smoke", "name": "Smoke", "reasoning": False, "input": ["text"],
                        "contextWindow": 128000, "maxTokens": 1024, "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]}}}))
        env = {**os.environ, "PI_CODING_AGENT_DIR": str(config), "XDG_STATE_HOME": str(root / "state"), "PI_TELEMETRY": "0"}
        for key in ("PI_SUBAGENT_CHILD", "PI_SUBAGENT_DEPTH", "PI_GOAL_QUOTA_URL"):
            env.pop(key, None)
        command = ["pi", "--offline", "--mode", "rpc", "--no-extensions", "--no-skills", "--no-mcp",
                   "--no-prompt-templates", "--no-context-files", "--no-themes", "-e", str(extension),
                   "--model", "smoke/smoke", "--session-dir", str(root / "sessions")]
        client = Pi(command, repo, env)
        try:
            client.command("get_state")
            client.command("prompt", message="/goal Exercise automatic continuation")
            client.wait(lambda e: e.get("type") == "agent_start")
            client.wait(lambda e: e.get("type") == "agent_start")
            # Pause out of band while the second goal turn is streaming.
            client.command("prompt", message="/goal-pause")
            client.wait(lambda e: e.get("type") == "agent_settled")
            state = client.command("get_state")
            session_file = state["sessionFile"]
            goals = list((root / "state" / "pi-goal" / "goals").glob("*.json"))
            assert len(goals) == 1
            assert json.loads(goals[0].read_text())["status"] == "paused"
            snapshots.extend(m for m in client.command("get_messages")["messages"] if m.get("customType") == "pi-goal")
            starts = sum(e.get("type") == "agent_start" for e in client.all)
            assert starts == 2, starts
            assert sum(e.get("type") == "turn_start" for e in client.all) == 2, "out-of-band pause must not enqueue a model request"
        finally:
            client.close()
        client = Pi(command + ["--session", session_file], repo, env)
        try:
            client.command("get_state")
            time.sleep(0.15)
            assert not any(e.get("type") == "agent_start" for e in client.all), "paused restart continued"
            client.command("prompt", message="/goal-resume")
            client.wait(lambda e: e.get("type") == "agent_start")
            client.command("prompt", message="/goal-pause")
            client.wait(lambda e: e.get("type") == "agent_settled")
            assert json.loads(goals[0].read_text())["status"] == "paused"
            snapshots.extend(m for m in client.command("get_messages")["messages"] if m.get("customType") == "pi-goal")
            assert not any("extension error" in line.lower() for line in client.errors), client.errors
        finally:
            client.close()
    server.shutdown()
    if args.adapter:
        javascript = '''
import assert from 'node:assert/strict';
const {piGoal} = await import(process.argv[1]);
let input=''; for await(const chunk of process.stdin) input += chunk;
const messages = JSON.parse(input); assert.ok(messages.length > 0);
const session = piGoal.createSession();
const statuses = new Set();
for(const message of messages) {
  const mapped = session.mapCustomMessage(message);
  assert.equal(mapped.suppressDefaultMessage, true);
  assert.equal(mapped.timeline[0].type, 'todo');
  statuses.add(mapped.timeline[0].items[0].status);
}
assert.ok(statuses.has('in_progress')); assert.ok(statuses.has('pending'));
assert.deepEqual(session.replay().timeline[0].items[0].status, 'pending');
console.log('PASS: actual Pi snapshots map to active/paused Paseo todos, suppress hidden prompts, and replay paused');
'''
        subprocess.run(["node", "--experimental-strip-types", "--input-type=module", "-e", javascript,
                        args.adapter.resolve().as_uri()], input=json.dumps(snapshots), text=True, check=True)
    print("PASS: real Pi /goal -> automatic continuation -> out-of-band pause -> restart paused -> resume -> pause")


if __name__ == "__main__":
    main()
