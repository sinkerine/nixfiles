# REALITY Fallback Traffic Guard (`reality-guard.nix`)

Reusable NixOS module providing kernel-level `nftables` protection for `sing-box` VLESS+REALITY servers against unauthenticated fallback bandwidth abuse and inbound port/connection scanning.

## How It Works

1. **Bidirectional Egress Fallback Policing (`meta skuid` + `ct mark` + `ct bytes`)**:
   - Periodic DNS resolver (`reality-guard-resolve.service` + `reality-guard-resolve.timer`) resolves configured `strictDomains` and `relaxedDomains` (IPv4 + IPv6) into `decoy_strict_{v4,v6}` and `decoy_relaxed_{v4,v6}`, retaining rotating CDN edge IPs for `ipRetentionSeconds` and preserving cached IPs on DNS failures.
   - A shared lock (`/var/lib/reality-guard/lock` in `StateDirectory` via `fcntl.flock`) serializes cache reread, merge/write, and `nft -f -` application across live resolution and `reality-guard-nft.service` start/reload (DNS lookups run outside the lock). Start and reload build a single atomic `nft -f -` transaction (`--render-ruleset`) combining the static rules and cached set elements, propagating any failure without leaving empty sets.
   - In `output`, TCP original-direction flows already carrying `0x00100000` (strict) or `0x00200000` (relaxed) are dispatched directly to their tier chain regardless of current set membership. Only `ct state new` flows owned by `singBoxUser` (`"sing-box"`) to TCP/443 in a decoy set are newly classified and marked (strict checked before relaxed; other mark bits preserved; established unmarked flows are never reclassified).
   - **Per-connection allowance + bandwidth + quota**:
     - Flows within `perConnAllowance` total bidirectional `ct bytes` pass unconditionally, ensuring legitimate REALITY handshakes (`~3–5 KiB`) are never blocked even if an attacker saturates the tier's bandwidth bucket.
     - Bytes above `perConnAllowance` are policed by the tier's shared `bandwidthRate` / `bandwidthBurst` token bucket across both `output` (`strict_bw_out_drop` / `relaxed_bw_out_drop`) and `input` (`strict_bw_in_drop` / `relaxed_bw_in_drop`).
     - Flows exceeding `perConnQuota` total bidirectional `ct bytes` are terminated with `reject with tcp reset` in both `output` (`strict_quota_out_drop` / `relaxed_quota_out_drop`) and `input` (`strict_quota_in_drop` / `relaxed_quota_in_drop`), closing both `sing-box` and decoy sockets promptly.
   - Authenticated proxy traffic to non-decoy destinations never matches the decoy sets and is untouched.
2. **Inbound Per-Source-IP Scan Protection**:
   - Limits new TCP connections (`inbound.newConnRate` / `inbound.newConnBurst`) and concurrent connections (`inbound.maxConnections`) per source IP on `inboundPorts` (`inbound_rate_drop` / `inbound_conn_drop`).
   - Exempts `inbound.exemptInterfaces` (default `lo`, `tailscale0`). SSH (22), Traefik (443), WireGuard, and TURN are unaffected.

## Module Options & Defaults (`my.services.realityGuard`)

| Option | Default | Description |
|---|---|---|
| `enable` | `false` | Enable the REALITY fallback guard. |
| `singBoxUser` | `"sing-box"` | System user running `sing-box` (`meta skuid`). |
| `strictDomains` | `[ ]` | Primary port 10087 decoy domains. |
| `relaxedDomains` | `[ ]` | Secondary/captive decoy domains. |
| `inboundPorts` | `[ ]` | Public REALITY TCP ports guarded per source IP. |
| `resolveInterval` | `"5min"` | Systemd timer interval for DNS resolution. |
| `ipRetentionSeconds` | `1800` | Retention window (seconds) for rotating decoy IPs. |
| `strict.bandwidthRate` / `bandwidthBurst` | `"256 kbytes/second"` / `"512 kbytes"` | Shared strict-tier bidirectional bandwidth cap. |
| `strict.perConnAllowance` | `32768` (32 KiB) | Unconditional per-flow byte allowance before `strict_bw`. |
| `strict.perConnQuota` | `1048576` (1 MiB) | Per-flow bidirectional byte cap before TCP RST. |
| `relaxed.bandwidthRate` / `bandwidthBurst` | `"5 mbytes/second"` / `"10 mbytes"` | Shared relaxed-tier bidirectional bandwidth cap. |
| `relaxed.perConnAllowance` | `32768` (32 KiB) | Unconditional per-flow byte allowance before `relaxed_bw`. |
| `relaxed.perConnQuota` | `67108864` (64 MiB) | Per-flow bidirectional byte cap before TCP RST. |
| `inbound.newConnRate` / `newConnBurst` | `"60/second"` / `150` | Per-source-IP new-connection rate on `inboundPorts`. |
| `inbound.maxConnections` | `512` | Per-source-IP concurrent TCP connection cap on `inboundPorts`. |
| `inbound.exemptInterfaces` | `[ "lo" "tailscale0" ]` | Interfaces exempted from inbound guard and return policing. |

## Conntrack Accounting (`nf_conntrack_acct`)

Bidirectional `ct bytes` rules require kernel conntrack byte accounting. When enabled, the module:
- Loads `nf_conntrack` early via `boot.kernelModules = [ "nf_conntrack" ]` so `boot.kernel.sysctl."net.netfilter.nf_conntrack_acct" = 1` applies cleanly at boot.
- Also runs `modprobe nf_conntrack`, `sysctl -w net.netfilter.nf_conntrack_acct=1`, and verifies `/proc/sys/net/netfilter/nf_conntrack_acct` reads `1` in `ExecStartPre` and `ExecReload` before any nftables transaction is applied.

## Inspection Commands

```bash
# Inspect table, sets, limits, and counters
nft list table inet reality_guard
nft -j list counters table inet reality_guard

# Check service and resolver timer status
systemctl status reality-guard-nft.service reality-guard-resolve.timer
journalctl -u reality-guard-resolve.service -n 50
```

## Compatibility Notes

- Manages an isolated `table inet reality_guard` directly via `nft`; **never** enables `networking.nftables.enable` and **never** runs `nft flush ruleset`.
- Coexists cleanly with `iptables-nft` (`networking.firewall`), Docker (`amane`, `sachi`), `networking.firewall.enable = false` (`sachi`), `sachi`'s `fwmark 0x53414348`, Tailscale, and `michiru`'s `routeros.nix` `extraCommands`.
- Ruleset syntax is validated at Nix build time against a real kernel netfilter parser via LKL (`lklWithFirewall` + `nft --check`).
- Option and domain validation is covered by `python3 tests/test-reality-guard-options.py`, and resolver behavior by `python3 tests/test-reality-guard-resolve.py`.
