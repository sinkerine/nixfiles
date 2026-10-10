import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
RENDERER = ROOT / "hosts/modules/services/networking/regional-proxy/render.py"


class RelayRendererTest(unittest.TestCase):
    def test_credentials_with_json_special_characters_round_trip(self):
        credentials = {
            "hk-direct-uuid": "hk-uuid",
            "us-exit-uuid": "us-uuid",
            "reality-private-key": "reality-key",
            "reality-short-id": "short-id",
            "tailnet-socks-user": 'tail"net\\user',
            "tailnet-socks-password": 'pass"word\\with\\slashes',
            "sachi-socks-user": "sachi-user",
            "sachi-socks-password": "sachi-password",
        }
        template = {
            "inbounds": [
                {
                    "type": "socks",
                    "users": [
                        {
                            "username": "@TAILNET_SOCKS_USER@",
                            "password": "@TAILNET_SOCKS_PASSWORD@",
                        }
                    ],
                }
            ]
        }

        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            credential_dir = root / "credentials"
            credential_dir.mkdir()
            for name, value in credentials.items():
                (credential_dir / name).write_text(value + "\n")
            template_path = root / "template.json"
            template_path.write_text(json.dumps(template))
            output_path = root / "rendered.json"

            subprocess.run(
                [sys.executable, str(RENDERER), str(template_path), str(output_path), str(credential_dir)],
                check=True,
            )

            rendered = json.loads(output_path.read_text())
            user = rendered["inbounds"][0]["users"][0]
            self.assertEqual(user["username"], credentials["tailnet-socks-user"])
            self.assertEqual(user["password"], credentials["tailnet-socks-password"])
            self.assertEqual(output_path.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main()
