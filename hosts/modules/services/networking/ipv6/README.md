# Native IPv6

RouterOS uses DHCPv6 prefix delegation and WAN router advertisements on
`sfp-sfpplus1`. Main LAN and guest Wi-Fi receive separate /64s via SLAAC with
RDNSS; Android clients do not need DHCPv6 address assignment. IPv4 DHCP, routes,
NAT, FastTrack, and regional routing remain unchanged. IPv6 uses native ISP
egress even when regional IPv4 routing is enabled.

Amane and its Docker services are excluded: its provider has no IPv6 allocation.

## RouterOS installation

`routeros.rsc` installs the firewall before enabling IPv6. Import it once, check
for errors (RouterOS SSH can return success despite script errors), and reboot
when `/ipv6 settings print` requires it. Existing installation is deliberately
rejected; inspect partial imports rather than deleting unrelated objects.

```sh
rtk scp routeros.rsc router:native-ipv6-import.rsc
rtk ssh router '/import file-name=native-ipv6-import.rsc'
rtk ssh router '/ipv6 settings print; /ipv6 dhcp-client print detail; /ipv6 pool print detail'
```

Once delegation is bound and contains at least two /64s, import
`routeros-lan.rsc`. It refuses a missing or insufficient pool. The current router
uses a /60 prefix hint; LAN addresses are allocated from the actual delegated
pool rather than a hardcoded public prefix.

```sh
rtk scp routeros-lan.rsc router:native-ipv6-lan.rsc
rtk ssh router '/import file-name=native-ipv6-lan.rsc'
```

WAN acceptance uses the existing `WAN` interface list, currently containing only
`sfp-sfpplus1`. RDNSS advertises each bridge's existing link-local address;
adjust those addresses if bridge MACs change. Default interface-wide RA is
disabled. Guest access to main LAN and router management is blocked; required
ICMPv6 and guest DNS remain available. Inbound WAN TCP 80/443 is allowed only
to sachi's current `::30` address. Other unsolicited inbound traffic is blocked.

`native-ipv6-prefix-sync` runs on DHCPv6 events and every minute. It updates
firewall prefixes, sachi's permitted web destination, and AAAA counterparts for
existing local A overrides targeting the router, kazuki, and sachi. Kazuki and
sachi accept RA on `vmbr0` with stable identifiers `::29` and `::30`.

## DNS and gateway

Sachi's `cloudflare-ipv6.timer` reconciles AAAA every two minutes using a SOPS
encrypted token scoped to DNS Write/Zone Read on `mado.moe`. It owns only AAAA
with comment `nixfiles-native-ipv6`; it refuses existing unmanaged AAAA and
never changes A/CNAME records, their TTLs, or proxy flags.

Public `mado.moe` points to sachi's stable native IPv6 address after native IPv6
egress and production origin TLS checks succeed. Failure withdraws only the
managed public AAAA so IPv4 remains available. Private sachi/kazuki/asako/yumiko
names receive verified Tailscale IPv6 addresses. Amane's private name and
`15cm.net` records are unchanged.

`my.services.gateway.enableIPv6` enables IPv6 loopback/Tailscale/Cloudflare
allowlists and a generated dynamic configuration. `gateway-ipv6-config.timer`
refreshes the current LAN prefix each minute, retaining existing router/service
configuration and access rules. Enabled only on kazuki and sachi.

## Rollback

Stop sachi's DNS timer first. Get its ExecStart from
`systemctl show cloudflare-ipv6 -p ExecStart`, then run the same Python command
with `--rollback` appended to delete only managed AAAA. Restore previous NixOS
generations on affected hosts. Import `routeros-rollback.rsc` to remove only
native IPv6 objects and restore the original globally disabled IPv6 setting;
reboot if RouterOS requests it. Preserve existing IPv4 objects and service data.

## Live status, 2026-10-08

- Delegation: `2600:1700:38d0:3bf0::/60`; main `3bf0::/64`, guest `3bf1::/64`.
- Native IPv6 egress confirmed from RouterOS and kazuki; stable sachi/kazuki
  addresses acquired, production headscale HTTPS over native IPv6 returns 200.
- Cloudflare AAAA published; DNS and gateway timers succeed. Local DNS returns
  both A and AAAA for home service overrides.
- Traefik file routes verified enabled after using a `.yaml` filename for the
  generated configuration. Private dashboard returns 200 over IPv4 and IPv6.
- Router IPv4 filter/NAT/mangle exports match the captured baseline. IPv4
  egress remains `45.30.94.38`; home HTTPS still responds through IPv4.
- Connected phones/VMs acquired main-LAN IPv6 automatically. Guest RA/prefix
  configured; live guest-device acceptance awaits a connected guest client.
- External Cloudflare AAAA-only probe reached origin TLS; router inbound web
  counter increased. Temporary probe hostname lacked an origin certificate
  (expected 526); record removed. Production hostname TLS passes.
- DHCPv6 renewal retained both /64s; prefix-sync scheduler remains active.
- Snapshot and prior system paths: `/tmp/ipv6-rollout-20261008` on kazuki.
  No persistent service data or Docker networks changed.
