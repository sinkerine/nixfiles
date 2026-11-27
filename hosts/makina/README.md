# Makina

Makina is the Android mobile host. Its sing-box Android profile generator lives in this directory.

The exporter writes `amane-tailscale`, `sachi-tailscale`,
`michiru-cn-direct-tailscale`, `michiru-always-proxy-tailscale`, and one `<server>-<target>-tailscale` profile for
both Amane and Sachi for every entry in
[`../common/reality-sni-targets.json`](../common/reality-sni-targets.json).
All profiles have a Tailscale endpoint enabled.

The shared SNI registry currently contains:

| Target | TLS SNI / REALITY handshake domain | Loopback listener |
| --- | --- | --- |
| `paypal` | `www.paypal.com` | 10092 |
| `alaskaair` | `alaskaair.com` | 10090 |
| `aa` | `www.aa.com` | 10091 |
| `delta` | `www.delta.com` | 10093 |
| `cathay` | `www.cathaypacific.com` | 10094 |

For example, select `amane-delta-tailscale` or `sachi-cathay-tailscale` on Android.
All registry profiles connect to the server on TCP/443. Traefik on Amane and
Sachi passes the registered SNI names through to matching REALITY listeners while
continuing to serve the existing HTTPS domains. The original PayPal listeners
remain available on Amane port 10088 and Sachi port 10089. Normal profiles on
port 10087 use the verified per-node institutional decoys from
[`../common/reality-primary-targets.json`](../common/reality-primary-targets.json)
(`amane`: `www.sinet.ad.jp`, `sachi`: `www.sdsc.edu`, `michiru`: `www.apple.com`),
embedded via `REALITY_PRIMARY_TARGETS_FILE` in the Nix-installed exporter.

To add another airline, add one entry to the shared registry:

```json
"another-airline": { "domain": "www.airline.example", "listen_port": 10095 }
```

Use a unique target name, domain, and unused unprivileged backend port on both
servers. The target name becomes part of the exported profile filename; `normal`
is reserved. Choose the actual TLS hostname used by the airline's allowed
website, with a publicly trusted certificate and TLS 1.3 support. Redirects do not
change the SNI sent in the initial TLS handshake. Local checks confirmed TLS 1.3
and HTTP/2 on `www.delta.com` and `www.cathaypacific.com`; access through a flight's
Wi-Fi still needs to be tested onboard.

The same registry generates Traefik routes, sing-box listeners, and Android
profiles, so no Python mode table or per-airline Nix routing edits are needed.
The Nix-installed exporter embeds the registry through `REALITY_SNI_TARGETS_FILE`;
source-tree invocation reads it from the repository by default.

Deploy the Amane/Sachi server changes and either Kazuki or Asako's updated
exporter (`hosts/makina/exporter.nix`, using `hosts/makina/secrets.yaml`), then
run `makina-sing-box-android-profiles` (writes to `/nas/storage/inbox/singbox`
by default; `asako-sing-box-android-profiles` remains as an alias on Asako) and
import the desired JSON profile into Android sing-box. Sachi's public TCP/443
must reach its Traefik listener through the upstream router. Backend listener
ports bind only to loopback and need no public firewall openings.

The spoofed profiles proxy public Internet traffic without the China-direct
rules; private network and tailnet routes remain enabled. Their Tailscale
endpoints use the selected SNI proxy as the detour, including on Sachi. Headscale
DNS resolution uses the proxy's DNS on Amane; Sachi uses a static Headscale LAN
address reached through the SNI proxy, avoiding its router's public-address TLS
service. Amane and Sachi profiles use V4/V6 dual-stack DNS and TUN addressing
by default; private tailnet IPv6 addresses remain routed through Tailscale.
Normal Sachi profiles retain their direct connection and LAN DNS behavior.

All variants for a server reuse its Tailscale identity and can use the normal
profile's enrollment key. The exporter removes only its exact legacy Amane, Sachi, and `michiru-cn`
output filenames when regenerating; it does not delete profiles for removed
registry entries, so remove those files manually when retiring a target.

The Michiru profile sends China destinations direct, forwards outbound tailnet
destinations (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) through `hk-direct` (so
Michiru's own Tailscale reaches the target peer, matching Asako), and sends
other destinations through Michiru. It keeps the embedded Tailscale endpoint
(reusing Makina's Sachi Tailscale identity because SFA runs only one profile at
a time). Its `hk-direct` and `hk-us` outbounds use dual-stack IPv4/IPv6 TCP/443 `urltest`
groups (`103.117.101.12` and `2403:18c0:4:3cb:be24:11ff:fe2e:3260`); encrypted
config still supplies credentials and TLS parameters. DNS remains `ipv4_only`
with tailnet-only IPv6 TUN routing because Sachi's US exit is IPv4-only.

`michiru-always-proxy-tailscale` removes the China-direct routing and DNS
exceptions. Public Internet traffic and DNS go through Michiru, retaining the
US exit rules for US IPs and configured US domains. Private LAN access and the
embedded Tailscale endpoint remain available, sharing the same Sachi identity.
It uses the same enrollment key as `michiru-cn-direct-tailscale` (or
`sachi-tailscale`) unless a profile-specific key is supplied.
