import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).parent


class RouterOsPlanTests(unittest.TestCase):
    def test_provisioner_quotes_routeros_cidr_selector(self):
        provisioner = (ROOT / "provision.sh").read_text()
        self.assertIn('where address="192.168.88.0/24"', provisioner)
        self.assertNotIn('where address=192.168.88.0/24', provisioner)

    def test_owned_setup_starts_disabled_and_guards_fasttrack_and_dnat(self):
        base = (ROOT / "regional-hk-base.rsc").read_text()
        for line in base.splitlines():
            if " add " in line and not line.startswith("/system script add") and "routing table add" not in line:
                self.assertIn("disabled=yes", line, line)
        self.assertIn("connection-mark=no-mark", base)
        self.assertIn("connection-nat-state=!dstnat", base)
        self.assertIn("dst-address-list=regional-hk-excluded", base)
        self.assertIn("blackhole routing-table=hk-cn distance=2 disabled=yes", base)
        self.assertIn("src-address=__US_EXIT_SOURCE_IPV4__ action=return", base)
        self.assertLess(base.index("src-address=__US_EXIT_SOURCE_IPV4__"), base.index("dst-address-list=regional-hk-excluded action=return"))
        self.assertLess(base.index("dst-address-list=regional-hk-excluded action=return"), base.index("new-connection-mark=regional-hk-cn"))
        on = base.split('name=regional-hk-on', 1)[1].split('name=regional-hk-off', 1)[0]
        self.assertLess(on.index('/ip firewall filter set $fasttrack'), on.index('/interface wireguard enable'))
        self.assertNotIn('firewall mangle move', on)
        self.assertNotIn('firewall nat move', on)
        self.assertNotIn('ipv6 firewall filter move', on)
        self.assertNotIn("connection remove", on)
        self.assertIn('regional-hk-state', on)
        self.assertIn('already enabled', on)
        self.assertIn('/ip dns cache flush', on)
        self.assertIn('regional-hk-state', base.split('name=regional-hk-off', 1)[1])
        self.assertIn("media.mado.moe", (ROOT.parent / "README.md").read_text())
        self.assertIn("192.168.88.31", (ROOT.parents[4] / "sachi/default.nix").read_text() + (ROOT.parents[4] / "modules/services/networking/regional-proxy/default.nix").read_text())
        self.assertIn("inet4_bind_address = config.my.services.regionalProxy.usExitSourceIPv4", (ROOT.parents[4] / "sachi/default.nix").read_text())

    def test_dns_and_ipv6_scope(self):
        allowlist = (ROOT / "allowlist.py").read_text()
        base = (ROOT / "regional-hk-base.rsc").read_text()
        routeros_module = (ROOT.parent / "routeros.nix").read_text()
        self.assertIn("resolveLocalQueries = false;", routeros_module)
        self.assertIn('LIST = "regional-hk-allowlist"', allowlist)
        self.assertIn("address-list={LIST}", allowlist)
        self.assertNotIn("/ipv6 firewall filter", base)
        self.assertNotIn("bridge_vlan2", base)
        self.assertIn("dns-server=192.168.88.1", base)
        self.assertIn("regionalHkDhcpDns", base)
        self.assertNotIn("/ip dns set allow-remote-requests=yes", base)
        self.assertIn('name="mado.moe"', base)
        self.assertIn(
            'name="weixin.qq.com" type=FWD forward-to=8.8.8.8 '
            'match-subdomain=yes address-list=regional-hk-excluded disabled=yes',
            base,
        )
        self.assertNotIn("address-list-extra-time", base)
        self.assertIn('DNS address-list-extra-time must be zero', allowlist)
        readme = (ROOT.parent / "README.md").read_text()
        self.assertIn("address-list-extra-time=0s", readme)
        self.assertIn("until the answer TTL expires", readme)

    def test_toggle_flushes_owned_marked_state(self):
        base = (ROOT / "regional-hk-base.rsc").read_text()
        off = base.split('name=regional-hk-off', 1)[1].split('name=regional-hk-status', 1)[0]
        self.assertLess(off.index("mangle disable"), off.index("connection remove"))
        self.assertIn(":foreach regionalHkConnection in=$regionalHkConnections", off)
        self.assertIn("on-error={}", off)
        self.assertIn("connection-mark=regional-hk-cn", off)
        self.assertIn("unset $fasttrack connection-mark", off)
        self.assertIn("address-list enable [find where comment=\"regional-hk-owned\" and dynamic=no]", base)

    def test_off_verifies_runtime_state_after_routeros_script_error(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            mock_ssh = root / "ssh"
            mock_ssh.write_text(
                "#!/bin/sh\n"
                "case \"$2\" in\n"
                "  *'script run regional-hk-off'*) printf 'no such item (4)\\n'; exit 0 ;;\n"
                "  *'firewall nat print count-only'*) printf '3\\r\\n'; exit 0 ;;\n"
                "  *) printf '0\\r\\n'; exit 0 ;;\n"
                "esac\n"
            )
            mock_ssh.chmod(0o700)
            env = os.environ | {"PATH": f"{root}:{os.environ['PATH']}", "ROUTEROS_SSH_TARGET": "mock-router"}
            result = subprocess.run([str(ROOT / "provision.sh"), "off"], env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("enabled regional NAT rules expected 0, found 3", result.stderr)

    def test_tracked_files_have_only_secret_placeholders(self):
        content = (ROOT / "regional-hk-base.rsc").read_text()
        self.assertNotRegex(content, r"private-key=[A-Za-z0-9+/]{40,}={0,2}")
        self.assertIn("__HK_ROUTER_PRIVATE_KEY__", content)
        self.assertIn('private-key="__HK_ROUTER_PRIVATE_KEY__"', content)

    def test_secret_files_are_encrypted_and_not_embedded_in_nix_or_scripts(self):
        for path in (
            ROOT / "routeros-secrets.yaml",
            ROOT.parents[4] / "michiru/regional-proxy-secrets.yaml",
        ):
            self.assertRegex(path.read_text(), r"wireguardPrivateKey: ENC\[")
        module = (ROOT.parent / "routeros.nix").read_text()
        self.assertIn("config.sops.secrets.regional-proxy-michiru-private-key.path", module)
        sachi_secrets = (ROOT.parents[4] / "sachi/regional-proxy-secrets.yaml").read_text()
        self.assertRegex(sachi_secrets, r"regionalProxySocksUser: ENC\[")
        self.assertRegex(sachi_secrets, r"regionalProxySocksPassword: ENC\[")
        sachi_recipients = set(re.findall(r"recipient: (age1[a-z0-9]+)", sachi_secrets))
        michiru_recipient = re.search(
            r"&michiru (age1[a-z0-9]+)",
            (ROOT.parents[5] / ".sops.yaml").read_text(),
        ).group(1)
        self.assertEqual(
            sachi_recipients,
            {
                "age147zmk06prg2864yym9tcg5z9vl9ldykv5zkwuuefuy85q994qp3sjh3lfd",  # Sachi host
                michiru_recipient,  # Current Michiru host key
                "age1sc2gp8d40y7d9engfqhydg5v6mcg0aj40x3yccndzh7ruxvj63cqcpax76",  # Kazuki recovery
            },
        )
        self.assertNotIn("pgp:", sachi_secrets)
        self.assertNotIn("privateKey = \"", module)

    def test_provisioner_cleans_sensitive_temp_files_and_remote_upload(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            bin_dir, run_dir = root / "bin", root / "run"
            bin_dir.mkdir()
            run_dir.mkdir()
            secret_file = root / "encrypted.yaml"
            secret_file.write_text("encrypted test fixture\n")
            peer_file = root / "peer.pub"
            peer_file.write_text((ROOT.parents[4] / "michiru/routeros-peer.pub").read_text())
            remote_file = root / "router-upload"
            import_called = root / "import-called"
            (bin_dir / "sops").write_text(
                "#!/bin/sh\n[ \"$1\" = --extract ] && [ \"$3\" = --decrypt ] || exit 2\n"
                "printf '%s\\n' \"${MOCK_PRIVATE_KEY:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}\"\n"
            )
            (bin_dir / "ssh").write_text(
                "#!/bin/sh\n"
                "case \"$2\" in *'/file remove '*) [ \"${MOCK_REMOVE_FAIL:-0}\" = 0 ] || exit 1; rm -f \"$MOCK_REMOTE\"; exit 0 ;; esac\n"
                "if [ -e \"$MOCK_IMPORT_CALLED\" ]; then\n"
                "  if [ \"${MOCK_EMPTY_IMPORT:-0}\" = 1 ]; then printf '0\\r\\n'; exit 0; fi\n"
                "  case \"$2\" in\n"
                "    *'name=\"wg-regional-hk\" and disabled=yes'*) printf '1\\r\\n' ;;\n"
                "    *'interface=\"wg-regional-hk\" and disabled=yes'*) printf '1\\r\\n' ;;\n"
                "    *'routing-table=\"hk-cn\" and comment=\"regional-hk-owned\" and disabled=yes'*) printf '2\\r\\n' ;;\n"
                "    *'/ip firewall address-list'*'disabled=yes'*) printf '16\\r\\n' ;;\n"
                "    *'/ip dns static'*'disabled=yes'*) printf '2\\r\\n' ;;\n"
                "    *'/ipv6 firewall filter'*) printf '0\\r\\n' ;;\n"
                "    *'comment=\"regional-hk-owned\" and disabled=yes'*)\n"
                "      case \"$2\" in *'firewall mangle'*) printf '5\\r\\n' ;; *'firewall nat'*) printf '3\\r\\n' ;; *) printf '1\\r\\n' ;; esac ;;\n"
                "    *'comment=\"regional-hk-owned\" and disabled=no'*) printf '0\\r\\n' ;;\n"
                "    *'name=\"hk-cn\"'*) printf '1\\r\\n' ;;\n"
                "    *'name~\"regional-hk\"'*) printf '4\\r\\n' ;;\n"
                "  esac\n"
                "  exit 0\n"
                "fi\n"
                "case \"$2\" in\n"
                "  *'/system resource get version'*) printf '%s\\r\\n' \"${MOCK_VERSION:-7.16.0}\" ;;\n"
                "  *'/ip dns get allow-remote-requests'*) printf '%s\\r\\n' \"${MOCK_DNS_STATE:-true}\" ;;\n"
                "  *'system script print count-only where name=\"regional-hk-on\"'*) printf '0\\r\\n' ;;\n"
                "  *'name=\"wg-regional-hk\"'*) printf '0\\r\\n' ;;\n"
                "  *'name=\"hk-cn\"'*) printf '0\\r\\n' ;;\n"
                "  *'comment=\"regional-hk-owned\"'*) printf '0\\r\\n' ;;\n"
                "  *'dhcp-server network print count-only'*'192.168.88.0/24'*) printf '1\\r\\n' ;;\n"
                "  *'print count-only'*) printf '1\\r\\n' ;;\n"
                "  *'dhcp-server network get'*) printf '192.168.88.1\\r\\n' ;;\n"
                "  *'firewall filter get'*) printf 'no-mark\\r\\n' ;;\n"
                "  *'/import file-name='*)\n"
                "    grep -q 'private-key=.*AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \"$MOCK_REMOTE\" || exit 1\n"
                "    grep -q 'regionalHkDhcpDns \\\"192.168.88.1\\\"' \"$MOCK_REMOTE\" || exit 1\n"
                "    grep -q 'regionalHkFastTrackMark \\\"no-mark\\\"' \"$MOCK_REMOTE\" || exit 1\n"
                "    touch \"$MOCK_IMPORT_CALLED\"\n"
                "    [ \"${MOCK_IMPORT_FAIL:-0}\" = 0 ] ;;\n"
                "  *'/file remove '* ) [ \"${MOCK_REMOVE_FAIL:-0}\" = 0 ] || exit 1; rm -f \"$MOCK_REMOTE\" ;;\n"
                "esac\n"
            )
            (bin_dir / "scp").write_text("#!/bin/sh\ncp \"$2\" \"$MOCK_REMOTE\"\n[ \"${MOCK_SCP_FAIL:-0}\" = 0 ]\n")
            generator = root / "lists.sh"
            generator.write_text(
                "#!/bin/sh\n: > \"$1\"\n"
            )
            for tool in bin_dir.iterdir():
                tool.chmod(0o700)
            generator.chmod(0o700)

            env = os.environ | {
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "MOCK_REMOTE": str(remote_file),
                "MOCK_IMPORT_CALLED": str(import_called),
                "REGIONAL_PROXY_ROUTEROS_SECRETS": str(secret_file),
                "MICHIRU_PEER_PUBLIC_KEY_FILE": str(peer_file),
                "ROUTEROS_SSH_TARGET": "mock-router",
                "REGIONAL_PROXY_LIST_GENERATOR": str(generator),
                "REGIONAL_PROXY_RUNTIME_DIR": str(run_dir),
            }
            success = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertEqual(success.returncode, 0, success.stderr)
            self.assertNotIn("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", success.stdout + success.stderr)
            self.assertTrue(import_called.exists())
            self.assertFalse(remote_file.exists())
            self.assertEqual(list(run_dir.iterdir()), [])

            if import_called.exists():
                import_called.unlink()
            env["MOCK_EMPTY_IMPORT"] = "1"
            empty_import = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(empty_import.returncode, 0)
            self.assertIn("regional WireGuard interface expected 1, found 0", empty_import.stderr)
            self.assertFalse(remote_file.exists())
            self.assertEqual(list(run_dir.iterdir()), [])
            env.pop("MOCK_EMPTY_IMPORT")

            env["MOCK_SCP_FAIL"] = "1"
            upload_failure = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(upload_failure.returncode, 0)
            self.assertFalse(remote_file.exists())
            self.assertEqual(list(run_dir.iterdir()), [])

            env["MOCK_IMPORT_FAIL"] = "1"
            env["MOCK_SCP_FAIL"] = "0"
            if import_called.exists():
                import_called.unlink()
            failure = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(failure.returncode, 0)
            self.assertTrue(import_called.exists())
            self.assertNotIn("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", failure.stdout + failure.stderr)
            self.assertFalse(remote_file.exists())
            self.assertEqual(list(run_dir.iterdir()), [])

            env["MOCK_IMPORT_FAIL"] = "0"
            if import_called.exists():
                import_called.unlink()
            env["MOCK_PRIVATE_KEY"] = "not-a-valid-private-key"
            bad_private = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(bad_private.returncode, 0)
            self.assertIn("private key", bad_private.stderr)
            self.assertFalse(import_called.exists())
            self.assertFalse(remote_file.exists())
            self.assertNotIn("not-a-valid-private-key", bad_private.stdout + bad_private.stderr)
            self.assertEqual(list(run_dir.iterdir()), [])
            env.pop("MOCK_PRIVATE_KEY")
            original_peer = peer_file.read_text()
            peer_file.write_text("not-a-valid-public-key\n")
            bad_public = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(bad_public.returncode, 0)
            self.assertIn("public key", bad_public.stderr)
            self.assertFalse(import_called.exists())
            self.assertFalse(remote_file.exists())
            self.assertNotIn("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", bad_public.stdout + bad_public.stderr)
            self.assertEqual(list(run_dir.iterdir()), [])
            peer_file.write_text(original_peer)

            env["MOCK_VERSION"] = "7.12.1 (stable)"
            if import_called.exists():
                import_called.unlink()
            sops_called = root / "sops-called"
            (bin_dir / "sops").write_text(
                "#!/bin/sh\ntouch \"$MOCK_SOPS_CALLED\"\nprintf 'not-a-real-key\\n'\n"
            )
            env["MOCK_SOPS_CALLED"] = str(sops_called)
            refusal = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(refusal.returncode, 0)
            self.assertIn("7.16.0 or newer", refusal.stderr)
            self.assertFalse(sops_called.exists())
            self.assertFalse(import_called.exists())
            self.assertEqual(list(run_dir.iterdir()), [])

            env.pop("MOCK_VERSION")
            env["MOCK_REMOVE_FAIL"] = "1"
            env["MOCK_IMPORT_FAIL"] = "0"
            env.pop("MOCK_SCP_FAIL")
            if import_called.exists():
                import_called.unlink()
            (bin_dir / "sops").write_text(
                "#!/bin/sh\nprintf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\\n'\n"
            )
            cleanup_failure = subprocess.run([str(ROOT / "provision.sh"), "install"], env=env, capture_output=True, text=True)
            self.assertNotEqual(cleanup_failure.returncode, 0)
            self.assertTrue(import_called.exists())
            self.assertIn("failed to remove remote temporary file", cleanup_failure.stderr)
            self.assertTrue(remote_file.exists())
            self.assertNotIn("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", cleanup_failure.stdout + cleanup_failure.stderr)
            remote_file.unlink()


if __name__ == "__main__":
    unittest.main()
