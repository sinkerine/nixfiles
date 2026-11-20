# Feature Plan: REALITY Fallback Traffic Guard (P0 + P1)

## 1. Problem & Motivation

VLESS+REALITY forwards unauthenticated TLS connections transparently to `handshake.server:443`. When `handshake.server` is a multi-tenant CDN domain such as `www.cloudflare.com`, an attacker can abuse a proxy server as a free traffic relay to reach arbitrary domains hosted on the same CDN (e.g. via SNI routing to OpenAI or large downloads), exhausting VPS bandwidth quotas and triggering provider abuse suspensions (e.g. DMIT AS32519 on `michiru`).

All three server nodes (`amane`, `sachi`, `michiru`) run `sing-box` 1.14.4, which lacks Xray's `limitFallbackUpload`/`limitFallbackDownload`. This plan implements **Option A (P0 + P1)**: keep `sing-box`, replace shared-CDN primary decoy domains with verified low-abuse institutional domains, and enforce kernel-level fallback rate/concurrency/bandwidth limits plus per-source inbound scan protection via a reusable NixOS `nftables` module.

## 2. Scope, Exclusions & Protected Boundaries

### In Scope
- **P0 — Primary Port 10087 Decoy Replacement**: Replace `www.cloudflare.com` with verified per-node dedicated-IP/own-ASN institutional domains across `amane`, `sachi`, and `michiru`, backed by a single source of truth (`hosts/common/reality-primary-targets.json`) consumed by all servers, NixOS clients (`kazuki`, `asako`), Android profile exporter (`makina`), and unit tests.
- **P1 — Reusable Kernel Guard Module (`hosts/modules/services/networking/reality-guard.nix`)**: Deployed on `amane`, `sachi`, and `michiru`:
  1. **Egress fallback precision throttling**: Periodic DNS resolver (`systemd` timer + cache) populates IPv4/IPv6 nftables sets for every configured REALITY `handshake.server` domain (`strict` tier for primary port 10087 decoys; `relaxed` tier for mobile/airline `reality-sni-targets.json` + `www.paypal.com`). Enforces total bidirectional bandwidth cap, concurrent connection cap, and new-connection rate limit strictly on sockets owned by `meta skuid "sing-box"` connecting to decoy IPs on TCP 443. Authenticated proxy traffic to non-decoy destinations is completely unaffected.
  2. **Inbound per-source-IP scan guard**: Conservative per-source-IP new-connection rate and concurrent-connection caps on public REALITY ports (`amane`: 10087, 10088; `sachi`: 10087, 10089; `michiru`: 10087), leaving SSH (22), Tailscale (`tailscale0`, UDP 41641), Traefik (80/443), WireGuard (51820), and TURN (3478/5349) untouched.
- **Compatibility**: Clean coexistence with `networking.firewall` (iptables-nft on `amane`/`michiru`, `mkForce false` on `sachi`), Docker (`amane`/`sachi`), Traefik (`amane`/`sachi`), Tailscale (all three), `sachi`'s `regionalProxy.usExit` (`fwmark 0x53414348`), and `michiru`'s `routeros.nix` `extraCommands` + NAT.

### Explicitly Excluded
- **P2** (node-level traffic circuit breaker / alerting).
- Migration from `sing-box` to Xray.
- Replacing `www.paypal.com` on 10088/10089 or airline domains in `hosts/common/reality-sni-targets.json` (these exist specifically for captive/in-flight Wi-Fi SNI allowlists and are guarded via P1 relaxed-tier rules instead).
- Modifying `hosts/modules/services/networking/ipv6/cloudflare.py` (unrelated Cloudflare DDNS/egress probe).
- **Remote deployment** (`deploy`, `nixos-rebuild switch` on remote hosts, or mutating any live host firewall). Build-only verification on `kazuki` + local unit tests + isolated VM E2E test (if approved).

### Protected State & Side-Effect Boundaries
- Never modify SOPS-encrypted secrets (`hosts/michiru/relay-secrets.yaml`, `hosts/*/secrets.yaml`). `hk_profile` in `hosts/makina/android-profiles.py` reads the Michiru primary SNI from `reality-primary-targets.json` by default (`config.get("server_name") or PRIMARY_TARGETS["michiru"]`), requiring zero secret file rewrites.
- Never enable `networking.nftables.enable = true` globally on `amane`, `sachi`, or `michiru` (see §4.1 rationale) and never run `nft flush ruleset`, protecting Docker, Tailscale, `iptables-nft`, and `routeros.nix` rules.
- Never alter `meta mark` / `fwmark` (`0x53414348` on `sachi`) or `forward` hook chains.

---

## 3. P0 Decoy Domain Selection & Probe Evidence

All probes were executed read-only on `2026-11-20` (PST) using `dig`, `ipinfo.io`, `openssl s_client -tls1_3 -groups X25519 -alpn h2`, `openssl s_client -tls1_3 -groups X25519MLKEM768:X25519 -alpn h2`, and `curl --http2 --tlsv1.3`.

Node locations verified via `ipinfo.io`:
- **`amane`** (`167.148.6.201`): Tokyo, JP (`AS43969 Prinode AB`)
- **`michiru`** (`103.117.101.12`): Kwai Chung, Hong Kong (`AS32519 DMIT Cloud Services`)
- **`sachi`**: US West residential (California)

| Node | Chosen Domain | DNS Records (A / AAAA) | IP Owner / ASN & Location | TLS 1.3 / ALPN / Key Share | Cert & HTTP/2 Check | Non-CDN & Low-Abuse Proof |
|---|---|---|---|---|---|---|
| **amane** (Tokyo, JP) | `www.sinet.ad.jp` | A: `150.100.0.25`, `150.100.1.25`<br>AAAA: `2001:2f8:a::25`, `2001:2f8:a:1::25`<br>CNAME: none | `AS2907` Research Organization of Information and Systems (NII / SINET), Tokyo, JP; PTR `www.sinet.ad.jp.` | `TLSv1.3`, `TLS_AES_256_GCM_SHA384`, `ALPN: h2`, `X25519 (253 bits)`, Verify `0 (ok)` | OV cert `CN=www.sinet.ad.jp` (NII Open Domain CA G8, valid Jun–Dec 2026); `HTTP/2 200` directly (Apache, 317 KB, no redirect) | Own academic backbone ASN in Tokyo; foreign SNI (`api.openai.com`) returns `www.sinet.ad.jp` cert (no multi-tenant SNI routing); plain institutional network info site (no video/downloads). |
| **michiru** (HK) | `hkust.edu.hk` | A: `143.89.209.9`<br>AAAA: none<br>CNAME: none | `AS3363` Hong Kong University of Science and Technology, Tseung Kwan O, HK; PTR `www.ust.hk.` | `TLSv1.3`, `TLS_AES_128_GCM_SHA256`, `ALPN: h2`, `X25519 (253 bits)` + `X25519MLKEM768`, Verify `0 (ok)` | Sectigo DV cert `CN=hkust.edu.hk` (SAN `hkust.edu.hk, *.hkust.edu.hk, *.ust.hk`, valid Nov 2025–Dec 2026); `HTTP/2 200` directly (nginx, 154 KB, no redirect) | Own university ASN in same HK metro as Michiru; foreign SNI (`api.openai.com`) returns `TRAEFIK DEFAULT CERT` (rejects foreign hosts, no shared CDN); university homepage widely accessible from mainland CN. |
| **sachi** (US West) | `www.sdsc.edu` | A: `132.249.112.52`<br>AAAA: none<br>CNAME: none | `AS195` San Diego Supercomputer Center, San Diego, CA, US; PTR `www.sdsc.edu.` | `TLSv1.3`, `TLS_AES_128_GCM_SHA256`, `ALPN: h2`, `X25519 (253 bits)` + `X25519MLKEM768`, Verify `0 (ok)` | Let's Encrypt `CN=www.sdsc.edu` (valid Nov 2026–Feb 2027); `HTTP/2 200` directly (Apache, 49 KB, 158 ms from kazuki, no redirect) | Single dedicated California IP on own institutional ASN (unlike `www.washington.edu`, which mixed AS73 with Google Cloud AS396982); foreign SNI (`api.openai.com`) returns `TRAEFIK DEFAULT CERT`; small static research center homepage. |

### Single Source of Truth (`hosts/common/reality-primary-targets.json`)
```json
{
  "amane": "www.sinet.ad.jp",
  "sachi": "www.sdsc.edu",
  "michiru": "hkust.edu.hk"
}
```
Consumed by:
- Servers: `hosts/amane/default.nix`, `hosts/sachi/default.nix`, `hosts/modules/services/networking/regional-proxy/relay.nix`
- Clients: `hosts/kazuki/default.nix`, `hosts/asako/default.nix`, `hosts/makina/android-profiles.py`, `hosts/modules/services/networking/regional-proxy/cn-client.nix` (via `REALITY_PRIMARY_TARGETS_FILE` + `REALITY_SNI_TARGETS_FILE` env vars so Nix-store execution of `android-profiles.py` from `asako-hk.py` never fails on relative paths)
- Tests: `hosts/asako/test-android-profiles.py`, `hosts/modules/services/networking/regional-proxy/test_asako_hk.py`, `tests/test-regional-proxy-relay.py`

---

## 4. P1 Architecture & Design Decisions

### 4.1 Standalone `table inet reality_guard` vs `networking.nftables.enable`
We **do NOT enable `networking.nftables.enable = true`** globally. Inspecting NixOS's `nftables.nix` and `firewall-nftables.nix` shows three concrete hazards on our hosts:
1. `networking.nftables.enable = true` blacklists `ip_tables` and defaults `flushRuleset = true` whenever `system.stateVersion < "23.11"` — both `amane` and `sachi` have `system.stateVersion = "22.05"` and run Docker, so enabling it would risk flushing Docker/Tailscale/iptables-nft tables on reload.
2. `michiru` uses `networking.firewall.extraCommands` / `extraStopCommands` (`hosts/modules/services/networking/regional-proxy/routeros.nix` TCPMSS clamping with `iptables`/`ip6tables`), which fails NixOS's `firewall-nftables.nix` assertion if the firewall backend switches to nftables.
3. `sachi` explicitly disables NixOS's host firewall (`networking.firewall.enable = mkForce false`).

Instead, `hosts/modules/services/networking/reality-guard.nix` manages an isolated, self-contained table **`table inet reality_guard`** via a dedicated systemd service (`reality-guard-nft.service`) invoking `${pkgs.nftables}/bin/nft`:
- Native `inet` nftables tables coexist cleanly alongside `iptables-nft` (Docker, Tailscale, `nixos-fw`, `routeros.nix`) in the Linux `nf_tables` kernel subsystem (kernels 6.12–6.18).
- Works identically whether `networking.firewall.enable` is `true` (`amane`, `michiru`) or `false` (`sachi`).
- Atomically replaces only `table inet reality_guard` (`table inet reality_guard; delete table inet reality_guard; table inet reality_guard { ... }`) on start/reload and deletes only `table inet reality_guard` on stop. Never runs `flush ruleset`.
- Uses `policy accept;` on both `input` and `output` at `priority filter + 10` (evaluating after `nixos-fw` drops closed ports on `input`, and after routing/`SO_MARK` on `output`). Never registers a `forward` hook.
- Self-contained NixOS module (no dependency on `mylib`, `config.my.ports`, or `config.my.ip`), imported from `hosts/modules/services/default.nix` (disabled by default) and explicitly imported in minimal host `hosts/michiru/default.nix`.

### 4.2 Bidirectional Egress Fallback Enforcement (`meta skuid` + `ct mark`)
**Key insight**: In a REALITY fallback download attack (attacker fetches large payloads from `decoy:443` through the VPS), `output` from `sing-box` to `decoy:443` carries mostly small HTTP requests and TCP ACKs (~52 B per 2–10 KB downloaded), while the bulk bytes arrive in `input` from `decoy:443`. Policing only `output` bytes would still allow 10–50× higher download throughput!

Therefore:
- In `output` (`priority filter + 10`, `oifname != "lo"`, `meta skuid == "sing-box"`, `tcp dport 443`):
  - Check `@decoy_strict_v4`/`@decoy_strict_v6` **before** `@decoy_relaxed_v4`/`@decoy_relaxed_v6` (so strict always wins on any overlap).
  - Inside `chain decoy_strict_out` (and analogously `chain decoy_relaxed_out`):
    1. `ct state new limit name "strict_conn_rate" counter drop` (new-connection rate limit)
    2. `ct state new ct count over <strict.maxConnections> counter drop` (shared IPv4+IPv6 concurrent connection cap)
    3. `ct state new ct mark set ct mark | 0x00100000` (bitmask-safe conntrack mark; `0x00200000` for relaxed — never touches `meta mark` / `0x53414348` or low `ct mark` bits)
    4. `limit name "strict_bw" counter drop` (shared named byte-rate `limit` object)
    5. `accept` (terminal for `table inet reality_guard`, preventing fall-through to relaxed)
- In `input` (`priority filter + 10`, after `iifname @exempt_ifaces accept` for `lo`, `tailscale0`):
  - `ct mark & 0x00100000 != 0 limit name "strict_bw" counter drop`
  - `ct mark & 0x00200000 != 0 limit name "relaxed_bw" counter drop`
  - Because `ct mark` is set **only** on `sing-box` → `decoy:443` flows, return traffic from decoy servers to `sing-box` is charged against the exact same `strict_bw`/`relaxed_bw` token bucket, capping **combined upload + download** while leaving non-`sing-box` host processes and all non-decoy `sing-box` proxy traffic completely untouched.
- All three hosts already define a static system user `users.users.sing-box = { isSystemUser = true; group = "sing-box"; };`, guaranteeing a stable UID for `meta skuid "sing-box"`.

### 4.3 Inbound Per-Source-IP Scan Protection
In `input` (after `iifname { "lo", "tailscale0" } accept` and decoy return policing), matching only `ct state new tcp dport @public_ports`:
- Per-source-IP new-connection rate (IPv4 & IPv6 separate dynamic sets, `size 65535`, `flags dynamic, timeout`, `timeout 5m`):
  `meta nfproto ipv4 ct state new tcp dport @public_ports update @inbound_rate_v4 { ip saddr limit rate over <rate> burst <burst> packets } counter drop`
- Per-source-IP concurrent connections (IPv4 & IPv6 separate dynamic sets, `size 65535`, `flags dynamic`, **no** `timeout` flag because `ct count` tracks conntrack entry lifetimes):
  `meta nfproto ipv4 ct state new tcp dport @public_ports add @inbound_conn_v4 { ip saddr ct count over <maxConnections> } counter drop`
- Public ports per host:
  - `amane`: `[ 10087, 10088 ]`
  - `sachi`: `[ 10087, 10089 ]`
  - `michiru`: `[ 10087 ]` (TCP 10088 on `michiru` is `tailscale0`-bound SOCKS, not public REALITY)
- TCP 443 (Traefik) is intentionally excluded from inbound scan limits so shared Cloudflare CDN source IPs and normal web traffic on `amane`/`sachi` are never throttled; Traefik's passthrough REALITY inbounds (`10090–10094`) remain fully protected on egress by P1.1.
- SSH (22), Tailscale (`tailscale0`, UDP 41641), WireGuard (51820), and TURN (3478/5349) never match `@public_ports`.

### 4.4 Default Thresholds & Rationale

All thresholds are exposed as typed NixOS options under `my.services.realityGuard`:

| Tier / Guard | Option | Default | Rationale |
|---|---|---|---|
| **Strict egress** (port 10087 decoys: `www.sinet.ad.jp`, `www.sdsc.edu`, `hkust.edu.hk`) | `strict.bandwidthRate` / `bandwidthBurst` | `"256 kbytes/second"` / `"512 kbytes"` | ≈ 2 Mbps combined cap (≤ ~21 GB/day worst case); allows TLS 1.3 handshake + single institutional page load smoothly while neutralizing bandwidth theft. Dedicated institutional IPs have zero shared-CDN collateral impact. |
| | `strict.maxConnections` | `16` | Total concurrent `sing-box` → strict decoy flows (IPv4+IPv6 combined). |
| | `strict.newConnRate` / `newConnBurst` | `"5/second"` / `10` | Blocks rapid fallback connection floods while allowing normal active probes. |
| **Relaxed egress** (`reality-sni-targets.json` + `www.paypal.com` on `amane`/`sachi`) | `relaxed.bandwidthRate` / `bandwidthBurst` | `"5 mbytes/second"` / `"10 mbytes"` | ≈ 40 Mbps combined cap; imperceptible for real users loading PayPal or airline check-in pages (or occasional shared Fastly/Akamai edge-IP hits) through the proxy while capping sustained CDN fallback abuse. |
| | `relaxed.maxConnections` | `128` | Accommodates multi-connection web pages and occasional shared Akamai/Fastly edge IPs. |
| | `relaxed.newConnRate` / `newConnBurst` | `"30/second"` / `60` | Handles parallel browser asset fetches without tripping. |
| **Inbound scan** (per source IP on public REALITY ports) | `inbound.newConnRate` / `newConnBurst` | `"60/second"` / `150` | Conservative ceiling sized for non-multiplexed `xtls-rprx-vision` when multiple devices (`kazuki`, `asako`, `makina`) share one home/CGNAT public IP during heavy browsing, `nix`/git bursts, or Wi-Fi↔5G reconnects, while blocking aggressive port/fallback floods. |
| | `inbound.maxConnections` | `512` | Generous per-source-IP concurrent TCP cap for multiple devices behind shared NAT; P1.1 already hard-caps egress fallback traffic regardless of inbound count. |
| | `inbound.exemptInterfaces` | `[ "lo" "tailscale0" ]` | Tailscale and loopback traffic never throttled. |

### 4.5 Dynamic Set Resolution, State & Lifecycle (`reality-guard-resolve.py`)
- **State file**: `/var/lib/reality-guard/cache.json` (systemd `StateDirectory = "reality-guard"`, `0750`, root-owned), storing `{ domain: { "v4": { ip: last_seen_ts }, "v6": { ip: last_seen_ts } } }`.
- **Units & ordering**:
  - `reality-guard-nft.service` (`Type = "oneshot"`, `RemainAfterExit = true`, `reloadIfChanged = true`):
    - `after = [ "network-pre.target" ]`, `before = [ "network.target" "sing-box-server.service" "sing-box-hk-relay.service" ]`, `wantedBy = [ "multi-user.target" ]`.
    - `ExecStart`: `nft -f ${rulesFile}`, followed by `ExecStartPost = "-${python3} ${resolveScript} --apply-cache-only ${configJson}"` (non-blocking, zero DNS I/O; restores cached IPs immediately on reboot/reload before `sing-box` starts, or no-ops cleanly on fresh first boot).
    - `ExecReload`: runs the same atomic `nft -f ${rulesFile}` + `--apply-cache-only` restore so `nixos-rebuild switch` never leaves decoy sets empty.
    - `ExecStop`: removes only `table inet reality_guard`.
  - `reality-guard-resolve.service` (`Type = "oneshot"`, `after = [ "reality-guard-nft.service" "network-online.target" ]`, `requires = [ "reality-guard-nft.service" ]`, `wants = [ "network-online.target" ]`, `wantedBy = [ "multi-user.target" ]`, `restartTriggers = [ configJson ]`, `TimeoutStartSec = "30s"`):
    - Resolves IPv4 (`AF_INET`) and IPv6 (`AF_INET6`) for every domain in `strictDomains` and `relaxedDomains` via `socket.getaddrinfo(domain, 443, type=SOCK_STREAM)`.
    - Merges freshly resolved IPs with cached entries still within `ipRetentionSeconds` (default `1800` = 30 min, absorbing rotating CDN edge IPs for PayPal/airlines).
    - **DNS failure / empty answer**: preserves all previously cached IPs for that failing domain (never flushes to empty) and logs a warning to stderr/journald; exits 0 if at least the nft transaction succeeded (so transient upstream DNS glitches do not trigger noisy failed-unit alerts, while still warning clearly; exits non-zero only if `nft -f -` itself fails).
    - **Empty sets (e.g. IPv6-less domains or `relaxedDomains = []` on `michiru`)**: emits `flush set inet reality_guard <set>` and omits `add element` when the IP list is empty (avoiding nftables' `{ }` empty-set syntax error).
    - **Atomic update**: submits all `flush set` + `add element` statements in a single `nft -f -` stdin transaction (zero unprotected window).
  - `reality-guard-resolve.timer` (`wantedBy = [ "timers.target" ]`):
    - `OnBootSec = "30s"`, `OnUnitActiveSec = "5min"` (configurable via `resolveInterval`), `RandomizedDelaySec = "15s"`.
- **Build-time ruleset syntax verification**:
  - `rulesFile` is built with `pkgs.writeTextFile` whose `checkPhase` runs `nft --check --file` under `pkgs.buildPackages.libredirect` + `pkgs.buildPackages.lklWithFirewall` (verified present in pinned nixpkgs with `CONFIG_NF_TABLES_INET`, `CONFIG_NFT_CONNLIMIT`, `CONFIG_NFT_CT`, `CONFIG_NFT_LIMIT`, `CONFIG_NFT_OBJREF`, `CONFIG_NF_CONNTRACK_MARK` all `=y`), redirecting `/etc/passwd` to include `${cfg.singBoxUser}:x:999:999::/:/sbin/nologin` plus `/etc/protocols` and `/etc/services`. Every `nixos-rebuild build` therefore validates the exact generated nftables ruleset against a real kernel netfilter parser.

---

## 5. Acceptance Criteria & Documentation Requirements

### Acceptance Criteria
- **AC1 (P0 Decoy Replacement & No Stale REALITY Cloudflare References)**: `amane` (`www.sinet.ad.jp`), `sachi` (`www.sdsc.edu`), and `michiru` (`hkust.edu.hk`) use the verified non-CDN primary domains from `hosts/common/reality-primary-targets.json` across all server configs, NixOS client configs (`kazuki`, `asako`), `asako-hk.py`, and Makina Android profiles; no REALITY config or test references `www.cloudflare.com` (unrelated `hosts/modules/services/networking/ipv6/cloudflare.py` untouched).
- **AC2 (Single Source of Truth & Store-Safe Client Rendering)**: `asako-sing-box-android-profiles` and `sing-box-hk-tun.service` pass `REALITY_PRIMARY_TARGETS_FILE` and `REALITY_SNI_TARGETS_FILE` from the Nix store so `android-profiles.py` and `asako-hk.py` render matching SNIs both from the source tree and when installed in `/nix/store`.
- **AC3 (Reusable Self-Contained Guard Module)**: `hosts/modules/services/networking/reality-guard.nix` provides typed options (`enable`, `singBoxUser`, `strictDomains`, `relaxedDomains`, `inboundPorts`, `strict.*`, `relaxed.*`, `inbound.*`, `resolveInterval`, `ipRetentionSeconds`), validates domain/port inputs via Nix `assertions`, builds cleanly on full hosts (`amane`, `sachi`) and minimal host (`michiru`), and stays a no-op when disabled (`kazuki`, `asako`, `yumiko`).
- **AC4 (Build-Time nftables Verification & Coexistence)**: Every `nixos-rebuild build --flake .#<host>` (`amane`, `sachi`, `michiru`, `kazuki`, `asako`, `yumiko`) succeeds; `reality-guard.nft` passes `nft --check` via LKL during build; `networking.nftables.enable` remains untouched so `amane`/`sachi` Docker + `sachi` `firewall.enable = false` + `sachi` `fwmark 0x53414348` + `michiru` `routeros.nix` `extraCommands` all coexist cleanly.
- **AC5 (Resolver Lifecycle & Fault Tolerance)**: `reality-guard-resolve.py` resolves IPv4+IPv6 into strict/relaxed nft sets atomically, skips empty `add element` blocks cleanly, retains rotating CDN IPs within `ipRetentionSeconds`, preserves previously cached IPs on DNS failures without wiping sets, and restores cached IPs immediately on `--apply-cache-only` without DNS I/O.
- **AC6 (Runtime Fallback & Inbound Enforcement — E2E if Approved)**: In the isolated NixOS VM test (if approved by the user):
  1. Timer/resolver populates `@decoy_strict_v4`, `@decoy_strict_v6`, and `@decoy_relaxed_v4`, and `reality-guard-nft.service` reload restores sets from cache.
  2. Authenticated VLESS+REALITY proxy traffic to a non-decoy target runs at full unthrottled speed with zero guard drops.
  3. Unauthenticated fallback traffic to the strict decoy is bandwidth-throttled (`strict_bw` drops > 0) and trips strict connection-rate/concurrency caps under flood.
  4. Relaxed decoy traffic is governed by the relaxed tier independently of strict counters.
  5. Inbound per-source-IP flood on port 10087 trips `inbound_rate_v4`/`inbound_conn_v4` drops for the attacker IP while a legitimate client from another IP still proxies cleanly and SSH (port 22) remains reachable even from the attacker IP.

### Required Documentation
- **D1**: Update `hosts/makina/README.md` to replace the outdated "Normal profiles still use Cloudflare SNI on port 10087" note with `hosts/common/reality-primary-targets.json` per-node decoys.
- **D2**: Add concise operator reference `hosts/modules/services/networking/reality-guard.md` documenting module options, default thresholds, inspection commands (`nft list table inet reality_guard`, `systemctl status reality-guard-nft reality-guard-resolve.timer`), and compatibility notes.
- **D3**: If the proposed NixOS VM E2E journey is approved, record its command, isolation boundaries, scratch path, and approved resource budget in root `AGENTS.md` (otherwise record the user's explicit E2E exemption per workflow rules).

---

## 6. E2E Classification & Proposed VM Journey (Requires Human Decision)

**Current status**: Root `AGENTS.md` has **no E2E journey instructions and no explicit E2E exemption → missing**.

### Proposed Isolated Journey (`tests/reality-fallback-guard-vm.nix`, exposed as `checks.x86_64-linux.reality-fallback-guard`)
A self-contained `pkgs.testers.runNixOSTest` booting **3 isolated QEMU/KVM micro-VMs** on a virtual LAN (zero internet dependency, zero host firewall/state mutation):
- **`server`** (1 vCPU, 1024 MiB): imports `reality-guard.nix`, runs `sing-box` 1.14.4 (`User = "sing-box"`) with REALITY inbounds on TCP `10087` (`decoy.test`) and `10088` (`relaxed.test`), `openssh` on TCP `22`, and `networking.firewall.enable = true` (iptables-nft coexistence). Maps `decoy.test` (IPv4+IPv6) and `relaxed.test` (IPv4) via `/etc/hosts` to `decoy`. Uses test-scaled thresholds (`strict` 64 KiB/s, 4 conns, 3/s; `relaxed` 512 KiB/s, 16 conns; `inbound` 5/s burst 8, 10 conns) so assertions complete deterministically in seconds.
- **`decoy`** (1 vCPU, 512 MiB): `nginx` TLS 1.3 + HTTP/2 on TCP `443` across three LAN IPs: `decoy.test` (IPv4 + IPv6, strict), `relaxed.test` (IPv4, relaxed), and `normal.test` (IPv4, non-decoy proxy target) serving deterministic blobs.
- **`client`** (1 vCPU, 512 MiB): two LAN source IPs — `192.168.1.10` running authenticated `sing-box` VLESS+REALITY client, and `192.168.1.11` acting as unauthenticated fallback abuser and port-10087 scanner.
- Executes all 6 assertions in AC6.

### Resource-Cost Proposal (for `kazuki`: 32 CPU, 60 GiB RAM)
- **Claimed resources**: **4 CPU, 4 GiB RAM**, `workers = 1` (3 guest vCPUs + 2 GiB guest RAM + QEMU/Nix overhead; ~12.5% CPU, ~6.7% RAM on `kazuki`).
- **Expected duration / timeout**: ~60–120 s wall time; timeout `600 s`.
- **Setup → Test → Teardown**:
  - Setup: `SCRATCH="${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/nixfiles/reality-fallback-guard-vm"; mkdir -p "$SCRATCH"`
  - Test: `nix build .#checks.x86_64-linux.reality-fallback-guard -o "$SCRATCH/result" --print-build-logs`
  - Teardown: QEMU VMs terminate automatically with the Nix sandbox build; remove `"$SCRATCH"` after verification.
- **Queueing / isolation**: Pure Nix sandbox derivation; zero host ports, zero live firewall changes, safe alongside desktop workloads.

---

## 7. Implementation Plan (Single Task T1)

No split needed — all P0 + P1 changes are tightly coupled around the same schema, module, and verification checks and form one coherent task **T1**.

### Implementing Surfaces
- **New files**:
  - `hosts/common/reality-primary-targets.json` — per-node primary REALITY decoy registry (`amane`, `sachi`, `michiru`)
  - `hosts/modules/services/networking/reality-guard.nix` — reusable NixOS guard module (nftables template + LKL `checkPhase` + systemd units/timer)
  - `hosts/modules/services/networking/reality-guard-resolve.py` — IPv4/IPv6 resolver, retention cache, DNS-failure resilience, atomic `nft -f -` updater
  - `hosts/modules/services/networking/reality-guard.md` — operator reference (D2)
  - `tests/test-reality-guard-resolve.py` — unit tests for resolver/cache/empty-set/DNS-failure/batch generation
  - `tests/reality-fallback-guard-vm.nix` — NixOS VM E2E test (only if E2E journey is approved)
- **Modified files**:
  - `hosts/modules/services/default.nix` — import `./networking/reality-guard.nix`
  - `hosts/amane/default.nix` — P0 `reality-main` SNI/handshake + P1 `my.services.realityGuard` config
  - `hosts/sachi/default.nix` — P0 `reality-main` SNI/handshake + P1 `my.services.realityGuard` config
  - `hosts/michiru/default.nix` — import `../modules/services/networking/reality-guard.nix` + P1 `my.services.realityGuard` config
  - `hosts/modules/services/networking/regional-proxy/relay.nix` — P0 `public-reality` SNI/handshake from `reality-primary-targets.json`
  - `hosts/modules/services/networking/regional-proxy/cn-client.nix` — pass `REALITY_SNI_TARGETS_FILE` and `REALITY_PRIMARY_TARGETS_FILE` in `sing-box-hk-tun.service` `Environment`
  - `hosts/kazuki/default.nix` — P0 `amane` outbound `server_name`
  - `hosts/asako/default.nix` — P0 `amane` & `sachiOutbound` `server_name` + export `REALITY_PRIMARY_TARGETS_FILE`
  - `hosts/makina/android-profiles.py` — load `PRIMARY_TARGETS` for `profile()` and `hk_profile()`
  - `hosts/makina/README.md` — D1 doc update
  - `hosts/asako/test-android-profiles.py`, `hosts/modules/services/networking/regional-proxy/test_asako_hk.py`, `tests/test-regional-proxy-relay.py` — update/add P0 assertions
  - `flake.nix` — merge `checks.x86_64-linux.reality-fallback-guard` (if E2E approved)
  - `AGENTS.md` — record approved E2E journey & resource budget (or explicit exemption)

### Exact Verification Commands
1. **Unit & regression tests**:
   ```bash
   python3 tests/test-reality-guard-resolve.py
   python3 hosts/asako/test-android-profiles.py
   python3 hosts/modules/services/networking/regional-proxy/test_asako_hk.py
   python3 tests/test-regional-proxy-relay.py
   ```
2. **Stale-reference sanity check**:
   ```bash
   rg 'www\.cloudflare\.com' hosts/ tests/
   # Expected: ONLY hosts/modules/services/networking/ipv6/cloudflare.py
   ```
3. **Host builds on `kazuki` (includes build-time LKL `nft --check` for `amane`, `sachi`, `michiru`)**:
   ```bash
   for host in amane sachi michiru kazuki asako yumiko; do
     nixos-rebuild build --flake ".#$host" --no-link
   done
   ```
   *(Note: remember `git add -N` on new untracked files before running flake builds.)*
4. **Isolated E2E VM test (if approved)**:
   ```bash
   SCRATCH="${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/nixfiles/reality-fallback-guard-vm"
   mkdir -p "$SCRATCH"
   nix build .#checks.x86_64-linux.reality-fallback-guard -o "$SCRATCH/result" --print-build-logs
   rm -rf "$SCRATCH"
   ```

### Criterion → Evidence Map
| AC | Real Entry Path | Verification / Evidence |
|---|---|---|
| AC1 | `hosts/common/reality-primary-targets.json` → server NixOS configs, client NixOS configs, `android-profiles.py` | `rg 'www\.cloudflare\.com' hosts/ tests/` + `test-android-profiles.py` + `test_asako_hk.py` + `test-regional-proxy-relay.py` |
| AC2 | `asako-sing-box-android-profiles` wrapper & `sing-box-hk-tun.service` `ExecStartPre` | `nixos-rebuild build --flake .#asako` + `test-android-profiles.py` + `test_asako_hk.py` |
| AC3 | `reality-guard.nix` NixOS module options & assertions | `nixos-rebuild build` on `amane`, `sachi`, `michiru`, `kazuki`, `asako`, `yumiko` |
| AC4 | `reality-guard.nft` `checkPhase` (`lklWithFirewall` + `nft --check`) & host module composition | Passing `nixos-rebuild build` on all 6 hosts without enabling `networking.nftables.enable` |
| AC5 | `reality-guard-resolve.py` CLI (`--apply-cache-only` & live resolve) | `python3 tests/test-reality-guard-resolve.py` |
| AC6 | `reality-guard-nft.service` + `reality-guard-resolve.service` + live `sing-box` 1.14.4 in QEMU VMs | `nix build .#checks.x86_64-linux.reality-fallback-guard` (if E2E approved) |

---

## 8. Approval

- **Status**: Approved by the user via `ask_user` on `2026-11-20T14:00:23-08:00 PST`.
- **Reviewed plan revision**: `sha256:456234fc06ff21bc` (SHA-256 prefix of `docs/features/reality-fallback-guard-plan.md` excluding `## 8. Approval`).
- **Approval questions (`ask_user`)**:
  1. `Final approval for docs/features/reality-fallback-guard-plan.md (rev 456234fc06ff21bc)?`
  2. `Confirm E2E verification decision?`
- **User response (verbatim)**:
  - Prior chat confirmations: `"Okay, sounds good. Approved"` (on adjusted relaxed/inbound thresholds), `"lg, approve"` (on 3-VM NixOS E2E journey).
  - Formal `ask_user` response:
    - `1. Final approval for docs/features/reality-fallback-guard-plan.md (rev 456234fc06ff21bc)? → Approve plan`
    - `2. Confirm E2E verification decision? → Approve VM E2E journey (4 CPU / 4 GiB)`
- **E2E & resource decision**: Approved — isolated 3-VM NixOS E2E journey (`tests/reality-fallback-guard-vm.nix` → `checks.x86_64-linux.reality-fallback-guard`) with claimed resource budget `4 CPU, 4 GiB RAM, workers = 1, timeout = 600s`, scratch under `${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/nixfiles/reality-fallback-guard-vm/`, to be recorded in root `AGENTS.md`.
