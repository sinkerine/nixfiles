# Michiru

Installed 2026-10-07: NixOS 26.11, 1 GiB RAM. Fixed IPv4 `103.117.101.12/32` via
`193.41.250.250`; ext4 root label `ROOT`; firewall enabled; QEMU Guest Agent
and serial output at 115200 baud. zram swap supports this one GiB VM.
Installation steps and recovery procedure: [Michiru bootstrap](../../bootstrap/michiru/README.md).

The host configuration enables the HK relay, RouterOS WireGuard peer, and TURN.
TCP 10087 provides public VLESS+REALITY; authenticated SOCKS is available through
`tailscale0` on TCP 10088. The public inbound has separate `hk-direct` and
`us-exit` users: HK-direct routes tailnet CIDRs over Tailscale and other
destinations through the HK uplink, while us-exit uses Sachi's authenticated
SOCKS exit.

The relay uses sing-box 1.14.1. SOPS provisions eight credential files through
symlinks in `/etc/regional-proxy/credentials/`: `hk-direct-uuid`, `us-exit-uuid`,
`reality-private-key`, `reality-short-id`, `tailnet-socks-user`,
`tailnet-socks-password`, `sachi-socks-user`, and `sachi-socks-password`.
Targets have mode `0400` and are owned by `sing-box:sing-box` while the relay is
enabled; the credential directory has mode `0750`. Relay credentials come from
`relay-secrets.yaml`; the Sachi SOCKS credentials come from Sachi's shared
encrypted file. The service renders config under `/run` and runs `sing-box check`
before starting. No credential value belongs in Nix expressions or the store.
`hosts/modules/services/networking/regional-proxy/relay-credentials.example`
lists the expected filenames.

Headscale enrollment uses `https://headscale.mado.moe`. SSH is key-only and uses
the configured administrator key. TURN and its IPv6 DNS reconciliation are
configured in `default.nix`; see the [regional proxy guide](../modules/services/networking/regional-proxy/README.md)
for endpoints, routing, provisioning, and remaining validation gaps.
