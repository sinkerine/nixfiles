"""Riichi mahjong scoreboard: serves index.html and a shared JSON state.

Clients POST full state with the version they based it on; stale writes get
409 plus the current state so the client can re-apply its change. Updates are
pushed to every open page over Server-Sent Events.
"""

import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("MAHJONG_HOST", "127.0.0.1")
PORT = int(os.environ.get("MAHJONG_PORT", "3020"))
STATE_FILE = os.path.join(os.environ.get("STATE_DIRECTORY", "."), "state.json")
INDEX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")
MAX_BODY = 1 << 20

cond = threading.Condition()
current = {"version": 0, "state": None}

try:
    with open(STATE_FILE) as f:
        current = json.load(f)
except (OSError, ValueError):
    pass


def save():
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(current, f)
    os.replace(tmp, STATE_FILE)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            with open(INDEX, "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/state":
            with cond:
                self.send_json(200, current)
        elif path == "/api/events":
            self.events()
        else:
            self.send_json(404, {"error": "not found"})

    def events(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        seen = -1
        try:
            while True:
                with cond:
                    if current["version"] == seen:
                        cond.wait(timeout=15)
                    snapshot = current if current["version"] != seen else None
                    if snapshot:
                        seen = snapshot["version"]
                        data = json.dumps(snapshot)
                if snapshot:
                    self.wfile.write(f"data: {data}\n\n".encode())
                else:
                    self.wfile.write(b": ping\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api/state":
            return self.send_json(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY:
            return self.send_json(413, {"error": "too large"})
        try:
            req = json.loads(self.rfile.read(length))
            base, state = int(req["baseVersion"]), req["state"]
        except (ValueError, KeyError, TypeError):
            return self.send_json(400, {"error": "bad request"})
        with cond:
            if base != current["version"]:
                return self.send_json(409, current)
            current["version"] += 1
            current["state"] = state
            save()
            cond.notify_all()
            self.send_json(200, current)


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    server.daemon_threads = True
    print(f"listening on {HOST}:{PORT}, state {STATE_FILE}", file=sys.stderr)
    server.serve_forever()
