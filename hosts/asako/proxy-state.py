#!/usr/bin/env python3
"""Persist and restore Asako's local TUN routing choice."""

import os
from pathlib import Path
import subprocess
import sys
import json
import time
from urllib.error import URLError
from urllib.request import Request, urlopen


STATE_DIR = Path(os.environ.get("ASAKO_PROXY_STATE_DIR", "/var/lib/asako-proxy"))
STATE_FILE = STATE_DIR / "state"
SYSTEMCTL = os.environ.get("ASAKO_SYSTEMCTL", "systemctl")
CLASH_API = os.environ.get("ASAKO_CLASH_API", "http://127.0.0.1:19090")


def save(choice):
    STATE_DIR.mkdir(mode=0o755, parents=True, exist_ok=True)
    temporary = STATE_DIR / "state.tmp"
    temporary.write_text(choice + "\n", encoding="ascii")
    temporary.chmod(0o644)
    temporary.replace(STATE_FILE)


def systemctl(action):
    subprocess.run([SYSTEMCTL, action, "sing-box-tun.service"], check=True)


def select(choice):
    if choice == "off":
        systemctl("stop")
        save("off")
        return

    if choice not in {"amane", "sachi"}:
        raise ValueError(f"invalid Asako proxy choice: {choice!r}")

    systemctl("start")
    request = Request(
        f"{CLASH_API}/proxies/proxy",
        data=json.dumps({"name": choice}).encode("ascii"),
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    last_error = None
    for _ in range(30):
        try:
            with urlopen(request, timeout=2):
                save(choice)
                return
        except (URLError, TimeoutError) as error:
            last_error = error
            time.sleep(1)
    raise RuntimeError(f"sing-box Clash API did not become ready: {last_error}")


def main(args):
    if len(args) == 1 and args[0] in {"off", "amane", "sachi", "on", "enable", "disable"}:
        select({"on": "amane", "enable": "amane", "disable": "off"}.get(args[0], args[0]))
    elif len(args) == 2 and args[0] == "restore" and args[1] in {"amane", "sachi", "off", "on"}:
        choice = STATE_FILE.read_text(encoding="ascii").strip() if STATE_FILE.exists() else args[1]
        select("amane" if choice == "on" else choice)
    else:
        raise SystemExit("usage: proxy-state.py off|amane|sachi|restore amane|sachi|off")


if __name__ == "__main__":
    main(sys.argv[1:])
