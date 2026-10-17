"""Allow a single configured HTTPS origin behind the LAN reverse proxy."""
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
old = '        host = _chat_authority(hosts[0]) if len(hosts) == 1 else None\n'
new = '''        import os
        public_origin = os.environ.get("LOOPX_WEB_ORIGIN", "")
        public_url = urlparse(public_origin)
        if (public_url.scheme == "https" and public_url.netloc
                and public_url.path == "" and not public_url.query and not public_url.fragment
                and hosts == [public_url.netloc]):
            if len(origins) > 1 or (origins and origins[0] != public_origin):
                self._send_error("LoopX Chat requires the configured browser origin.", status=403)
                return False
            self._cors_origin = origins[0] if origins else None
            return True
''' + old
assert text.count(old) == 1
path.write_text(text.replace(old, new))
