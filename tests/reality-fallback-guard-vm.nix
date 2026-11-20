{ pkgs }:

let
  testUuid = "11111111-2222-3333-4444-555555555555";
  testShortId = "0123456789abcdef";
  testPrivateKey = "0Npp8Ld89iDbJke6qNaf02agFvW3ZjJ8Xx3xffn0Z08";
  testPublicKey = "_CCODXwpGuwF5riifQxj8TQKl6ocGl9JeMNzN9dW-GE";

  testCerts = pkgs.runCommand "reality-guard-test-certs" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p "$out"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$out/ca.key" -out "$out/ca.crt" \
      -days 3650 -subj "/CN=RealityGuardTestCA" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign"

    cat > "$out/san.ext" <<'EOF'
    basicConstraints=CA:FALSE
    keyUsage=digitalSignature,keyEncipherment
    extendedKeyUsage=serverAuth
    subjectAltName=DNS:decoy.test,DNS:relaxed.test,DNS:normal.test
    EOF

    openssl req -newkey rsa:2048 -nodes \
      -keyout "$out/server.key" -out "$out/server.csr" \
      -subj "/CN=decoy.test"

    openssl x509 -req -in "$out/server.csr" \
      -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial \
      -out "$out/server.crt" -days 3650 -extfile "$out/san.ext"
  '';

  wwwRoot = pkgs.runCommand "reality-guard-test-www" { } ''
    mkdir -p "$out"
    printf 'ok-small\n' > "$out/small"
    head -c 2097152 /dev/zero > "$out/blob"
  '';

  serverSingBoxConfig = pkgs.writeText "sing-box-server.json" (
    builtins.toJSON {
      log = {
        level = "info";
      };
      inbounds = [
        {
          type = "vless";
          tag = "vless-strict";
          listen = "0.0.0.0";
          listen_port = 10087;
          users = [
            {
              uuid = testUuid;
              flow = "xtls-rprx-vision";
            }
          ];
          tls = {
            enabled = true;
            server_name = "decoy.test";
            reality = {
              enabled = true;
              handshake = {
                server = "decoy.test";
                server_port = 443;
              };
              private_key = testPrivateKey;
              short_id = [ testShortId ];
            };
          };
        }
        {
          type = "vless";
          tag = "vless-relaxed";
          listen = "0.0.0.0";
          listen_port = 10088;
          users = [
            {
              uuid = testUuid;
              flow = "xtls-rprx-vision";
            }
          ];
          tls = {
            enabled = true;
            server_name = "relaxed.test";
            reality = {
              enabled = true;
              handshake = {
                server = "relaxed.test";
                server_port = 443;
              };
              private_key = testPrivateKey;
              short_id = [ testShortId ];
            };
          };
        }
      ];
      outbounds = [
        {
          type = "direct";
          tag = "direct";
        }
      ];
    }
  );

  clientSingBoxConfig = pkgs.writeText "sing-box-client.json" (
    builtins.toJSON {
      log = {
        level = "info";
      };
      inbounds = [
        {
          type = "socks";
          tag = "socks-in";
          listen = "127.0.0.1";
          listen_port = 1080;
        }
      ];
      outbounds = [
        {
          type = "vless";
          tag = "proxy";
          server = "192.168.2.1";
          server_port = 10087;
          inet4_bind_address = "192.168.2.10";
          uuid = testUuid;
          flow = "xtls-rprx-vision";
          tls = {
            enabled = true;
            server_name = "decoy.test";
            utls = {
              enabled = true;
              fingerprint = "chrome";
            };
            reality = {
              enabled = true;
              public_key = testPublicKey;
              short_id = testShortId;
            };
          };
        }
      ];
    }
  );
in
pkgs.testers.runNixOSTest {
  name = "reality-fallback-guard";

  nodes = {
    server =
      { pkgs, ... }:
      {
        imports = [ ../hosts/modules/services/networking/reality-guard.nix ];

        virtualisation = {
          cores = 1;
          memorySize = 1024;
        };

        networking = {
          useDHCP = false;
          interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = "192.168.2.1";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = "fd00:2::1";
                prefixLength = 64;
              }
            ];
          };
          extraHosts = ''
            192.168.2.20 decoy.test
            fd00:2::20 decoy.test
            192.168.2.21 relaxed.test
            192.168.2.22 normal.test
          '';
          firewall = {
            enable = true;
            allowedTCPPorts = [
              22
              10087
              10088
            ];
          };
        };

        services.openssh.enable = true;

        users.users.sing-box = {
          isSystemUser = true;
          group = "sing-box";
        };
        users.groups.sing-box = { };

        systemd.services.sing-box-server = {
          description = "Test sing-box REALITY server";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
            "reality-guard-nft.service"
          ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${serverSingBoxConfig}";
            User = "sing-box";
            Group = "sing-box";
            Restart = "on-failure";
          };
        };

        my.services.realityGuard = {
          enable = true;
          resolveInterval = "15s";
          strictDomains = [ "decoy.test" ];
          relaxedDomains = [ "relaxed.test" ];
          inboundPorts = [
            10087
            10088
          ];
          strict = {
            bandwidthRate = "64 kbytes/second";
            bandwidthBurst = "64 kbytes";
            perConnAllowance = 16 * 1024;
            perConnQuota = 256 * 1024;
          };
          relaxed = {
            bandwidthRate = "512 kbytes/second";
            bandwidthBurst = "512 kbytes";
            perConnAllowance = 16 * 1024;
            perConnQuota = 2 * 1024 * 1024;
          };
          inbound = {
            newConnRate = "6/second";
            newConnBurst = 8;
            maxConnections = 10;
          };
        };

        environment.systemPackages = with pkgs; [
          conntrack-tools
          nftables
          python3
        ];
      };

    decoy =
      { pkgs, ... }:
      {
        virtualisation = {
          cores = 1;
          memorySize = 512;
        };

        networking = {
          useDHCP = false;
          interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = "192.168.2.20";
                prefixLength = 24;
              }
              {
                address = "192.168.2.21";
                prefixLength = 24;
              }
              {
                address = "192.168.2.22";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = "fd00:2::20";
                prefixLength = 64;
              }
            ];
          };
          firewall.allowedTCPPorts = [ 443 ];
        };

        services.nginx = {
          enable = true;
          virtualHosts."decoy.test" = {
            listen = [
              {
                addr = "192.168.2.20";
                port = 443;
                ssl = true;
              }
              {
                addr = "[fd00:2::20]";
                port = 443;
                ssl = true;
              }
            ];
            onlySSL = true;
            sslCertificate = "${testCerts}/server.crt";
            sslCertificateKey = "${testCerts}/server.key";
            root = wwwRoot;
          };
          virtualHosts."relaxed.test" = {
            listen = [
              {
                addr = "192.168.2.21";
                port = 443;
                ssl = true;
              }
            ];
            onlySSL = true;
            sslCertificate = "${testCerts}/server.crt";
            sslCertificateKey = "${testCerts}/server.key";
            root = wwwRoot;
          };
          virtualHosts."normal.test" = {
            listen = [
              {
                addr = "192.168.2.22";
                port = 443;
                ssl = true;
              }
            ];
            onlySSL = true;
            sslCertificate = "${testCerts}/server.crt";
            sslCertificateKey = "${testCerts}/server.key";
            root = wwwRoot;
          };
        };
      };

    client =
      { pkgs, ... }:
      {
        virtualisation = {
          cores = 1;
          memorySize = 512;
        };

        security.pki.certificateFiles = [ "${testCerts}/ca.crt" ];

        networking = {
          useDHCP = false;
          interfaces.eth1 = {
            ipv4.addresses = [
              {
                address = "192.168.2.10";
                prefixLength = 24;
              }
              {
                address = "192.168.2.11";
                prefixLength = 24;
              }
            ];
            ipv6.addresses = [
              {
                address = "fd00:2::10";
                prefixLength = 64;
              }
            ];
          };
          extraHosts = ''
            192.168.2.20 decoy.test
            fd00:2::20 decoy.test
            192.168.2.21 relaxed.test
            192.168.2.22 normal.test
          '';
        };

        systemd.services.sing-box-client = {
          description = "Test sing-box VLESS+REALITY client";
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig = {
            ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${clientSingBoxConfig}";
            Restart = "on-failure";
          };
        };

        environment.systemPackages = with pkgs; [
          curl
          python3
          openssl
        ];
      };
  };

  testScript = ''
    import datetime as dt
    import json
    import time

    EXPECTED_COUNTERS = {
        "strict_bw_out_drop",
        "strict_bw_in_drop",
        "strict_quota_out_drop",
        "strict_quota_in_drop",
        "relaxed_bw_out_drop",
        "relaxed_bw_in_drop",
        "relaxed_quota_out_drop",
        "relaxed_quota_in_drop",
        "inbound_rate_drop",
        "inbound_conn_drop",
    }

    def get_counters():
        raw = server.succeed("nft -j list counters table inet reality_guard")
        data = json.loads(raw)
        result = {}
        for item in data.get("nftables", []):
            if "counter" in item:
                c = item["counter"]
                result[c["name"]] = c["packets"]
        assert set(result.keys()) == EXPECTED_COUNTERS, (
            f"unexpected counter set: {set(result.keys())} != {EXPECTED_COUNTERS}"
        )
        return result

    def delta(after, before):
        return {k: after[k] - before[k] for k in EXPECTED_COUNTERS}

    def get_set_elements(set_name):
        raw = server.succeed(f"nft -j list set inet reality_guard {set_name}")
        data = json.loads(raw)
        for item in data.get("nftables", []):
            if "set" in item:
                return item["set"].get("elem", [])
        return []

    def wait_for_phase_drain(label):
        t0 = time.monotonic()
        deadline = t0 + 60.0
        active_states = ("ESTABLISHED", "SYN_SENT", "SYN_RECV", "CLOSE_WAIT")
        while True:
            strict_rows = server.succeed(
                "conntrack -L --mark 0x00100000/0x00100000 2>/dev/null"
            ).splitlines()
            relaxed_rows = server.succeed(
                "conntrack -L --mark 0x00200000/0x00200000 2>/dev/null"
            ).splitlines()
            strict_active = [r for r in strict_rows if any(s in r for s in active_states)]
            relaxed_active = [r for r in relaxed_rows if any(s in r for s in active_states)]
            if not strict_active and not relaxed_active:
                a = get_counters()
                time.sleep(2.0)
                b = get_counters()
                if a == b:
                    break
                print(f"{label}: counters still changing {a} -> {b}")
            else:
                print(
                    f"{label}: active marked conntrack rows remaining:\n"
                    f"strict={strict_active or '(none)'}\n"
                    f"relaxed={relaxed_active or '(none)'}"
                )
                time.sleep(1.0)
            if time.monotonic() >= deadline:
                all_strict = "\n".join(strict_rows)
                all_relaxed = "\n".join(relaxed_rows)
                print(
                    f"{label}: TIMEOUT conntrack rows:\n"
                    f"strict:\n{all_strict or '(none)'}\n"
                    f"relaxed:\n{all_relaxed or '(none)'}"
                )
                raise AssertionError(f"{label}: drain timed out after 60s")
        print(f"{label}: drained in {time.monotonic() - t0:.2f}s")

    start_all()
    decoy.wait_for_unit("nginx.service")
    decoy.wait_for_open_port(443, "192.168.2.20")
    decoy.wait_for_open_port(443, "192.168.2.21")
    decoy.wait_for_open_port(443, "192.168.2.22")
    server.wait_for_unit("reality-guard-nft.service")
    server.wait_for_unit("reality-guard-resolve.timer")
    server.wait_for_unit("sing-box-server.service")
    server.wait_for_unit("sshd.service")
    server.wait_for_open_port(10087)
    server.wait_for_open_port(10088)
    client.wait_for_unit("sing-box-client.service")
    client.wait_for_open_port(1080, "127.0.0.1")

    # Cross-node reachability probe from client (192.168.2.10) to server REALITY port
    client.succeed(
        "python3 -c \"import socket; s = socket.socket(); s.settimeout(5); "
        "s.bind(('192.168.2.10', 0)); s.connect(('192.168.2.1', 10087)); s.close()\""
    )

    # Verify nf_conntrack_acct=1 after boot and before table application in unit ordering
    acct_boot = server.succeed("cat /proc/sys/net/netfilter/nf_conntrack_acct").strip()
    print(f"nf_conntrack_acct after boot: {acct_boot}")
    assert acct_boot == "1", f"expected nf_conntrack_acct=1 after boot, got {acct_boot!r}"
    unit_pre = server.succeed("systemctl show reality-guard-nft.service -p ExecStartPre").strip()
    assert "nf_conntrack_acct=1" in unit_pre and "test" in unit_pre, unit_pre

    # AC6.1: Resolver populates sets, reload restores from cache, and timer repopulates after flush
    server.succeed("systemctl start reality-guard-resolve.service")
    s_v4 = get_set_elements("decoy_strict_v4")
    s_v6 = get_set_elements("decoy_strict_v6")
    r_v4 = get_set_elements("decoy_relaxed_v4")
    print(f"AC6.1 resolved sets: strict_v4={s_v4}, strict_v6={s_v6}, relaxed_v4={r_v4}")
    assert "192.168.2.20" in s_v4, s_v4
    assert "fd00:2::20" in s_v6, s_v6
    assert "192.168.2.21" in r_v4, r_v4

    server.succeed("systemctl reload reality-guard-nft.service")
    acct_reload = server.succeed("cat /proc/sys/net/netfilter/nf_conntrack_acct").strip()
    print(f"nf_conntrack_acct after reload: {acct_reload}")
    assert acct_reload == "1", f"expected nf_conntrack_acct=1 after reload, got {acct_reload!r}"
    s_v4_rel = get_set_elements("decoy_strict_v4")
    s_v6_rel = get_set_elements("decoy_strict_v6")
    r_v4_rel = get_set_elements("decoy_relaxed_v4")
    print(f"AC6.1 post-reload sets: strict_v4={s_v4_rel}, strict_v6={s_v6_rel}, relaxed_v4={r_v4_rel}")
    assert "192.168.2.20" in s_v4_rel
    assert "fd00:2::20" in s_v6_rel
    assert "192.168.2.21" in r_v4_rel

    server.succeed("systemctl stop reality-guard-resolve.timer reality-guard-resolve.service")
    server.succeed("nft flush set inet reality_guard decoy_strict_v4")
    assert get_set_elements("decoy_strict_v4") == []
    server.succeed("systemctl start reality-guard-resolve.timer")
    server.succeed("systemctl is-active reality-guard-resolve.timer")
    server.wait_until_succeeds(
        "nft -j list set inet reality_guard decoy_strict_v4 | grep -q 192.168.2.20",
        timeout=dt.timedelta(seconds=60),
    )
    print(f"AC6.1 timer repopulated strict_v4={get_set_elements('decoy_strict_v4')}")

    # AC6.2: Authenticated proxy to normal.test is unthrottled with zero guard drops
    t0 = time.monotonic()
    size = client.succeed(
        "curl -sf --socks5-hostname 127.0.0.1:1080 https://normal.test/blob | wc -c"
    ).strip()
    elapsed = time.monotonic() - t0
    counters = get_counters()
    print(f"AC6.2 authenticated proxy: bytes={size}, elapsed={elapsed:.3f}s, counters={counters}")
    assert size == "2097152", f"expected 2097152 bytes, got {size}"
    assert elapsed < 2.0, f"authenticated proxy too slow ({elapsed:.2f}s >= 2.0s), possible throttling"
    for name, pkts in counters.items():
        assert pkts == 0, f"expected zero drops during authenticated proxy, got {name}={pkts}"

    # AC6.3a & AC6.3b: Unauthenticated fallback > quota is throttled (strict_bw_drop > 0) and cut off at quota (strict_quota_drop > 0)
    c0 = get_counters()
    client.execute(
        "curl -sk --interface 192.168.2.11 --resolve decoy.test:10087:192.168.2.1 "
        "--max-time 12 https://decoy.test:10087/blob -o /tmp/ac63.out || true"
    )
    received = int(client.succeed("wc -c < /tmp/ac63.out").strip())
    c1 = get_counters()
    d = delta(c1, c0)
    print(f"AC6.3a/b received_bytes={received}, delta={d}, counters={c1}")
    ct_after_63ab = server.succeed(
        "conntrack -L --mark 0x00100000/0x00100000 2>/dev/null"
    ).strip()
    print(f"AC6.3a/b strict conntrack rows:\n{ct_after_63ab or '(none)'}")
    assert d["strict_bw_out_drop"] + d["strict_bw_in_drop"] > 0, (
        f"expected strict_bw_{{out,in}}_drop delta > 0, got {d}"
    )
    assert d["strict_quota_out_drop"] + d["strict_quota_in_drop"] > 0, (
        f"expected strict_quota_{{out,in}}_drop delta > 0, got {d}"
    )
    assert received <= 262144 + 65536, f"expected received <= 327680 bytes, got {received}"

    # AC6.3c: While >=4 concurrent fallback downloads saturate strict_bw, authenticated .10 proxy succeeds promptly (< 3s)
    wait_for_phase_drain("pre-AC6.3c")
    c0 = get_counters()
    out_63c = client.succeed(
        "python3 - <<'EOF'\n"
        "import subprocess, time\n"
        "from concurrent.futures import ThreadPoolExecutor\n"
        "def attacker(_):\n"
        "    subprocess.run(\n"
        "        ['curl', '-sk', '--interface', '192.168.2.11', '--resolve', 'decoy.test:10087:192.168.2.1',\n"
        "         '--max-time', '6', 'https://decoy.test:10087/blob', '-o', '/dev/null'],\n"
        "        check=False,\n"
        "    )\n"
        "with ThreadPoolExecutor(max_workers=5) as ex:\n"
        "    futs = [ex.submit(attacker, i) for i in range(5)]\n"
        "    time.sleep(0.5)\n"
        "    t0 = time.monotonic()\n"
        "    out = subprocess.check_output(\n"
        "        ['curl', '-sf', '--socks5-hostname', '127.0.0.1:1080', 'https://normal.test/small'],\n"
        "        text=True,\n"
        "    ).strip()\n"
        "    auth_elapsed = time.monotonic() - t0\n"
        "    for f in futs:\n"
        "        f.result()\n"
        "assert out == 'ok-small', f'expected ok-small, got {out!r}'\n"
        "assert auth_elapsed < 3.0, f'authenticated proxy took {auth_elapsed:.3f}s (>= 3.0s) under fallback saturation'\n"
        "print(f'auth_proxy={out} auth_elapsed={auth_elapsed:.3f}s')\n"
        "EOF"
    )
    c1 = get_counters()
    d = delta(c1, c0)
    print(f"AC6.3c {out_63c.strip()} delta={d}")
    assert d["strict_bw_out_drop"] + d["strict_bw_in_drop"] > 0, (
        f"expected strict_bw_{{out,in}}_drop delta > 0 during saturation, got {d}"
    )

    # AC6.3c-midflow (F3): Mid-transfer set flush still enforces quota on marked flow (output + input)
    wait_for_phase_drain("pre-F3-midflow")
    server.succeed("systemctl stop reality-guard-resolve.timer reality-guard-resolve.service")
    client.succeed(
        "systemd-run --unit=f3-download --collect "
        "curl -sk --interface 192.168.2.11 --resolve decoy.test:10087:192.168.2.1 "
        "--limit-rate 16k --max-time 25 https://decoy.test:10087/blob -o /tmp/f3.out"
    )
    server.wait_until_succeeds(
        "conntrack -L --mark 0x00100000/0x00100000 2>/dev/null | grep -q ESTABLISHED",
        timeout=dt.timedelta(seconds=10),
    )
    server.succeed("nft flush set inet reality_guard decoy_strict_v4")
    assert get_set_elements("decoy_strict_v4") == []
    c0 = get_counters()
    client.wait_until_succeeds(
        "! systemctl is-active --quiet f3-download.service",
        timeout=dt.timedelta(seconds=35),
    )
    received_f3 = int(client.succeed("wc -c < /tmp/f3.out").strip())
    c1 = get_counters()
    d = delta(c1, c0)
    print(f"F3 mid-flow flush (post-flush baseline): received_bytes={received_f3}, delta={d}")
    assert d["strict_quota_out_drop"] > 0 or d["strict_bw_out_drop"] > 0, (
        f"expected output-side strict drop after mid-flow flush, got {d}"
    )
    assert received_f3 <= 262144 + 65536, f"expected received <= 327680 bytes after mid-flow flush, got {received_f3}"
    server.succeed("systemctl start reality-guard-resolve.service")
    server.succeed("systemctl start reality-guard-resolve.timer")

    # AC6.4: Relaxed decoy tier operates independently of strict counters
    wait_for_phase_drain("pre-AC6.4")
    c0 = get_counters()
    client.execute(
        "curl -sk --interface 192.168.2.11 --resolve relaxed.test:10088:192.168.2.1 "
        "--max-time 6 https://relaxed.test:10088/blob -o /dev/null || true"
    )
    c1 = get_counters()
    d = delta(c1, c0)
    print(f"AC6.4 relaxed delta={d}")
    assert d["relaxed_bw_out_drop"] + d["relaxed_bw_in_drop"] > 0, (
        f"expected relaxed_bw_{{out,in}}_drop delta > 0, got {d}"
    )
    assert d["strict_bw_out_drop"] == 0 and d["strict_bw_in_drop"] == 0, (
        f"unexpected strict_bw drop during relaxed phase: {d}"
    )
    assert d["strict_quota_out_drop"] == 0 and d["strict_quota_in_drop"] == 0, (
        f"unexpected strict_quota drop during relaxed phase: {d}"
    )

    # AC6.5a: Inbound concurrency flood (> 10) from 192.168.2.11 trips inbound_conn_drop
    # while legitimate client (192.168.2.10) proxies cleanly and SSH from .11 works
    wait_for_phase_drain("pre-AC6.5a")
    c0 = get_counters()
    out_5a = client.succeed(
        "python3 - <<'EOF'\n"
        "import socket, subprocess, time\n"
        "held = []\n"
        "failed = 0\n"
        "for _ in range(14):\n"
        "    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
        "    s.settimeout(0.8)\n"
        "    s.bind(('192.168.2.11', 0))\n"
        "    try:\n"
        "        s.connect(('192.168.2.1', 10087))\n"
        "        held.append(s)\n"
        "    except Exception:\n"
        "        failed += 1\n"
        "        s.close()\n"
        "    time.sleep(0.18)\n"
        "assert failed >= 1, f'expected at least 1 attacker connect failure, got {failed} (held={len(held)})'\n"
        "# Legitimate client (192.168.2.10) proxies cleanly while attacker holds are active\n"
        "out = subprocess.check_output(\n"
        "    ['curl', '-sf', '--socks5-hostname', '127.0.0.1:1080', 'https://normal.test/small'],\n"
        "    text=True,\n"
        ").strip()\n"
        "assert out == 'ok-small', f'expected ok-small, got {out!r}'\n"
        "# SSH port 22 remains reachable from attacker IP 192.168.2.11 while holds are active\n"
        "ssh_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
        "ssh_sock.settimeout(3.0)\n"
        "ssh_sock.bind(('192.168.2.11', 0))\n"
        "ssh_sock.connect(('192.168.2.1', 22))\n"
        "banner = ssh_sock.recv(64)\n"
        "ssh_sock.close()\n"
        "assert b'SSH-' in banner, banner\n"
        "print(f'held={len(held)} failed={failed} proxy={out} ssh={banner.decode().strip()}')\n"
        "for s in held:\n"
        "    s.close()\n"
        "EOF"
    )
    c1 = get_counters()
    d = delta(c1, c0)
    print(f"AC6.5a {out_5a.strip()} delta={d}")
    assert d["inbound_conn_drop"] > 0, f"expected inbound_conn_drop delta > 0, got {d}"

    # AC6.5b: Inbound rate burst (> 6/s + burst 8) from 192.168.2.11 trips inbound_rate_drop
    time.sleep(2.5)
    c0 = get_counters()
    out_5b = client.succeed(
        "python3 - <<'EOF'\n"
        "import socket\n"
        "from concurrent.futures import ThreadPoolExecutor\n"
        "def probe(_):\n"
        "    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)\n"
        "    s.settimeout(0.6)\n"
        "    s.bind(('192.168.2.11', 0))\n"
        "    try:\n"
        "        s.connect(('192.168.2.1', 10087))\n"
        "        s.close()\n"
        "        return True\n"
        "    except Exception:\n"
        "        s.close()\n"
        "        return False\n"
        "with ThreadPoolExecutor(max_workers=20) as ex:\n"
        "    results = list(ex.map(probe, range(20)))\n"
        "failed = sum(1 for ok in results if not ok)\n"
        "assert failed >= 1, f'expected at least 1 rate-limited failure, got {failed}'\n"
        "print(f'total=20 failed={failed}')\n"
        "EOF"
    )
    c1 = get_counters()
    d = delta(c1, c0)
    print(f"AC6.5b {out_5b.strip()} delta={d}")
    assert d["inbound_rate_drop"] > 0, f"expected inbound_rate_drop delta > 0, got {d}"
  '';
}
