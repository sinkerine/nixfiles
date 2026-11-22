{
  config,
  pkgs,
  ...
}:

let
  syncScript = pkgs.writers.writePython3 "bookorbit-collection-sync" {
    flakeIgnore = [ "E501" "W503" ];
  } ''
    import email.utils
    import fcntl
    import json
    import os
    import re
    import sys
    import tempfile
    import urllib.error
    import urllib.parse
    import urllib.request
    from pathlib import Path

    BASE_URL = os.environ.get("BOOKORBIT_URL", "https://book.sachi.m.mado.moe").rstrip("/")
    API_KEY_FILE = Path(os.environ["BOOKORBIT_API_KEY_FILE"])
    SYNC_ROOT = Path("/pool/main/sync")
    TMP_DIR = SYNC_ROOT / ".bookorbit-sync-tmp"
    STATE_FILE = SYNC_ROOT / ".bookorbit-sync-state.json"
    LOCK_FILE = SYNC_ROOT / ".bookorbit-sync.lock"

    COLLECTIONS = {
        "book-to-read": {
            "dest": SYNC_ROOT / "book-to-read",
            "layout": "series_or_flat",
        },
        "book-to-read-manga": {
            "dest": SYNC_ROOT / "book-to-read-manga",
            "layout": "mihon",
        },
    }


    def sanitize_component(name: str, max_bytes: int = 180) -> str:
        name = re.sub(r'[\\/:*?"<>|\x00-\x1f]', " ", name)
        name = re.sub(r"\s+", " ", name).strip(" .")
        if not name:
            return "untitled"
        encoded = name.encode("utf-8")
        if len(encoded) > max_bytes:
            name = encoded[:max_bytes].decode("utf-8", errors="ignore").rstrip(" .")
        return name or "untitled"


    def api_get_json(path: str, api_key: str) -> object:
        req = urllib.request.Request(
            f"{BASE_URL}{path}",
            headers={
                "Authorization": f"Bearer {api_key}",
                "Accept": "application/json",
            },
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8"))


    def list_collection_books(collection_id: int, api_key: str) -> list[dict]:
        items: list[dict] = []
        page = 0
        size = 100
        while True:
            data = api_get_json(
                f"/api/v1/collections/{collection_id}/books?page={page}&size={size}",
                api_key,
            )
            batch = data.get("items", [])
            items.extend(batch)
            total = data.get("total", len(items))
            if not batch or len(items) >= total:
                break
            page += 1
        return items


    def pick_primary_file(book: dict) -> dict | None:
        files = book.get("files") or []
        for role in ("primary", "content"):
            for f in files:
                if f.get("role") == role:
                    return f
        return None


    def build_rel_path(book: dict, file_info: dict, layout: str, used: set[Path]) -> Path:
        title = (book.get("title") or "").strip()
        authors_list = [a.strip() for a in (book.get("authors") or []) if a and a.strip()]
        authors = ", ".join(authors_list)
        series = (book.get("seriesName") or "").strip()
        fmt = (file_info.get("format") or "").strip().lstrip(".")
        ext = f".{fmt}" if fmt else ""

        if title and authors:
            base = f"{title} - {authors}"
        elif title:
            base = title
        else:
            base = f"book-{book['id']}"

        stem = sanitize_component(base, max_bytes=180)
        filename = f"{stem}{ext}"

        if layout == "mihon":
            folder = sanitize_component(series or title or f"book-{book['id']}", max_bytes=120)
            candidate = Path(folder) / filename
        elif series:
            folder = sanitize_component(series, max_bytes=120)
            candidate = Path(folder) / filename
        else:
            candidate = Path(filename)

        if candidate in used:
            book_id = book["id"]
            disambig = f"{sanitize_component(base, max_bytes=160)} ({book_id}){ext}"
            candidate = (candidate.parent / disambig) if candidate.parent != Path(".") else Path(disambig)

        used.add(candidate)
        return candidate


    def load_state() -> dict:
        if not STATE_FILE.is_file():
            return {}
        try:
            return json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}


    def save_state(state: dict) -> None:
        TMP_DIR.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(prefix=".state-", dir=TMP_DIR)
        os.close(fd)
        tmp_path = Path(tmp_name)
        try:
            tmp_path.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
            os.chmod(tmp_path, 0o644)
            os.replace(tmp_path, STATE_FILE)
        except BaseException:
            tmp_path.unlink(missing_ok=True)
            raise


    def download_file_if_changed(
        file_id: int,
        dst: Path,
        api_key: str,
        cached_etag: str | None,
    ) -> tuple[bool, str | None]:
        headers = {"Authorization": f"Bearer {api_key}"}
        if cached_etag and dst.is_file():
            headers["If-None-Match"] = cached_etag

        req = urllib.request.Request(
            f"{BASE_URL}/api/v1/books/files/{file_id}/download",
            headers=headers,
        )
        try:
            resp = urllib.request.urlopen(req, timeout=120)
        except urllib.error.HTTPError as exc:
            if exc.code == 304:
                return False, cached_etag
            raise

        with resp:
            etag = resp.headers.get("ETag")
            last_mod = resp.headers.get("Last-Modified")
            TMP_DIR.mkdir(parents=True, exist_ok=True)
            dst.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp_name = tempfile.mkstemp(prefix=".dl-", dir=TMP_DIR)
            tmp_path = Path(tmp_name)
            try:
                with os.fdopen(fd, "wb") as out:
                    while True:
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        out.write(chunk)
                os.chmod(tmp_path, 0o644)
                if last_mod:
                    try:
                        dt = email.utils.parsedate_to_datetime(last_mod)
                        ts = dt.timestamp()
                        os.utime(tmp_path, (ts, ts))
                    except (TypeError, ValueError):
                        pass
                os.replace(tmp_path, dst)
            except BaseException:
                tmp_path.unlink(missing_ok=True)
                raise
            return True, etag


    def sync_collection(
        col_name: str,
        col_id: int,
        cfg: dict,
        api_key: str,
        col_state: dict,
    ) -> dict:
        dest: Path = cfg["dest"]
        layout: str = cfg["layout"]
        dest.mkdir(parents=True, exist_ok=True)

        books = list_collection_books(col_id, api_key)
        desired: dict[Path, dict] = {}
        used: set[Path] = set()
        for book in books:
            file_info = pick_primary_file(book)
            if file_info is None:
                print(
                    f"[{col_name}] skipping book {book.get('id')} without primary/content file",
                    file=sys.stderr,
                )
                continue
            rel = build_rel_path(book, file_info, layout, used)
            desired[rel] = file_info

        new_state: dict[str, dict] = {}
        downloaded = 0
        skipped = 0
        for rel, file_info in desired.items():
            rel_key = str(rel)
            dst = dest / rel
            file_id = file_info["id"]
            size_bytes = file_info.get("sizeBytes")
            prev = col_state.get(rel_key) or {}
            cached_etag = (
                prev.get("etag")
                if prev.get("fileId") == file_id
                and dst.is_file()
                and (size_bytes is None or dst.stat().st_size == size_bytes)
                else None
            )
            changed, etag = download_file_if_changed(file_id, dst, api_key, cached_etag)
            new_state[rel_key] = {"fileId": file_id, "etag": etag}
            if changed:
                downloaded += 1
                print(f"[{col_name}] downloaded: {rel}")
            else:
                skipped += 1

        removed = 0
        for root, dirs, files in os.walk(dest, topdown=False):
            root_path = Path(root)
            rel_root = root_path.relative_to(dest)
            if rel_root.parts and rel_root.parts[0].startswith("."):
                continue
            for fname in files:
                if rel_root == Path(".") and fname.startswith("."):
                    continue
                rel_file = (rel_root / fname) if rel_root != Path(".") else Path(fname)
                if rel_file not in desired:
                    (root_path / fname).unlink()
                    removed += 1
                    print(f"[{col_name}] removed: {rel_file}")
            for dname in dirs:
                if rel_root == Path(".") and dname.startswith("."):
                    continue
                try:
                    (root_path / dname).rmdir()
                except OSError:
                    pass

        print(f"[{col_name}] done: total={len(desired)} downloaded={downloaded} skipped={skipped} removed={removed}")
        return new_state


    def main() -> int:
        LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOCK_FILE.open("w") as lock_fh:
            fcntl.flock(lock_fh.fileno(), fcntl.LOCK_EX)
            api_key = API_KEY_FILE.read_text(encoding="utf-8").strip()
            try:
                collections = api_get_json("/api/v1/collections", api_key)
            except urllib.error.URLError as exc:
                print(f"BookOrbit API unreachable ({exc}); skipping sync", file=sys.stderr)
                return 0

            by_name = {c["name"]: c["id"] for c in collections if "name" in c and "id" in c}
            state = load_state()

            for col_name, cfg in COLLECTIONS.items():
                if col_name not in by_name:
                    print(f"[{col_name}] collection not found in BookOrbit; skipping", file=sys.stderr)
                    continue
                state[col_name] = sync_collection(
                    col_name,
                    by_name[col_name],
                    cfg,
                    api_key,
                    state.get(col_name) or {},
                )

            save_state(state)
        return 0


    if __name__ == "__main__":
        raise SystemExit(main())
  '';

  triggerServer = pkgs.writers.writePython3 "bookorbit-collection-sync-trigger" {
    flakeIgnore = [ "E501" ];
  } ''
    import json
    import subprocess
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    SYNC_BIN = "${syncScript}"


    class Handler(BaseHTTPRequestHandler):
        def _send_json(self, code: int, payload: dict) -> None:
            body = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            self._send_json(200, {"ok": True, "hint": "POST to trigger BookOrbit collection sync"})

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length > 0:
                self.rfile.read(min(length, 65536))
            proc = subprocess.run(
                [SYNC_BIN],
                capture_output=True,
                text=True,
                timeout=300,
            )
            ok = proc.returncode == 0
            self._send_json(
                200 if ok else 500,
                {
                    "ok": ok,
                    "returncode": proc.returncode,
                    "stdout": proc.stdout,
                    "stderr": proc.stderr,
                },
            )


    if __name__ == "__main__":
        server = ThreadingHTTPServer(("127.0.0.1", 18765), Handler)
        server.serve_forever()
  '';
in
{
  sops.secrets.bookorbitApiKey = {
    owner = "sinkerine";
    group = "sinkerine";
  };

  sops.templates."traefik-bookorbit.env" = {
    owner = "traefik";
    group = "traefik";
    content = ''
      BOOKORBIT_API_KEY=${config.sops.placeholder.bookorbitApiKey}
    '';
  };

  systemd.services.traefik.serviceConfig.EnvironmentFile = [
    config.sops.templates."traefik-bookorbit.env".path
  ];

  services.traefik.dynamicConfigOptions.http = {
    middlewares = {
      bookorbit-auth-header.headers.customRequestHeaders.Authorization = "Bearer {{ env `BOOKORBIT_API_KEY` }}"; # raw-string literal: double quotes get escaped in the JSON file and break Traefik's template parse
      bookorbit-lan-auth.chain.middlewares = [
        "lan-only@file"
        "bookorbit-auth-header@file"
      ];
    };
    routers.bookorbit-sync-trigger = {
      rule = "Host(`book-sync.sachi.m.mado.moe`)";
      middlewares = [ "lan-only@file" ];
      service = "bookorbit-sync-trigger";
    };
    services.bookorbit-sync-trigger.loadBalancer.servers = [
      { url = "http://127.0.0.1:18765"; }
    ];
  };

  systemd.services.bookorbit-collection-sync-trigger = {
    description = "HTTP trigger for BookOrbit collection sync";
    wantedBy = [ "multi-user.target" ];
    after = [
      "sachi-zfs-unlock.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathIsMountPoint = "/pool/main";
    environment = {
      BOOKORBIT_URL = "https://book.sachi.m.mado.moe";
      BOOKORBIT_API_KEY_FILE = config.sops.secrets.bookorbitApiKey.path;
    };
    serviceConfig = {
      Type = "simple";
      User = "sinkerine";
      Group = "sinkerine";
      Restart = "on-failure";
      RestartSec = 5;
      ExecStart = "${triggerServer}";
    };
  };

  systemd.services.bookorbit-collection-sync = {
    description = "Sync BookOrbit collections to Syncthing folders";
    after = [
      "sachi-zfs-unlock.service"
      "network-online.target"
    ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathIsMountPoint = "/pool/main";
    environment = {
      BOOKORBIT_URL = "https://book.sachi.m.mado.moe";
      BOOKORBIT_API_KEY_FILE = config.sops.secrets.bookorbitApiKey.path;
    };
    serviceConfig = {
      Type = "oneshot";
      User = "sinkerine";
      Group = "sinkerine";
      ExecStart = "${syncScript}";
    };
  };

  systemd.timers.bookorbit-collection-sync = {
    description = "Periodically sync BookOrbit collections to Syncthing folders";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "2min";
      Persistent = true;
    };
  };
}
