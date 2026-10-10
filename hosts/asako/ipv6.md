# Asako IPv6 operations

Asako uses NetworkManager automatic IPv6 for new or unmanaged profiles. IPv6
is optional (`ipv6.may-fail`), so a network without router advertisements or
IPv6 connectivity can still complete its IPv4 connection. Existing saved Wi-Fi
profiles keep their own settings. Inspect them with `nmcli connection show`; if
a profile explicitly disables IPv6, update that profile in place:

```sh
nmcli connection modify '<profile>' ipv6.method auto ipv6.may-fail yes
```

This modifies persistent profile state. Back up the profile first with
`nmcli connection export '<profile>'` when a rollback copy is needed. No saved
profiles are replaced by the NixOS configuration.

Asako's Traefik gateway trusts loopback and the Tailscale IPv4 and IPv6 ranges
for internal routes. It does not learn trust from a physical interface, since
the laptop roams across networks. External routes retain the configured
Cloudflare source ranges. Shared gateways continue to learn current global
IPv6 prefixes only from their explicitly configured trusted interface (default
`vmbr0`); missing interfaces and invalid/deprecated addresses produce base
allowlists without stale learned prefixes.

SSH remains key-only. Its source patterns permit the existing Tailscale IPv4
and LAN IPv4 ranges plus the Tailscale IPv6 `/48`; no general IPv6 source or
roaming native LAN is authorized.

## Deploy and verify

1. Record `nixos-rebuild list-generations` and export any saved NetworkManager
   profile that needs migration.
2. Build and deploy the Asako configuration using the normal deploy procedure.
3. On an IPv6-capable network, verify `ip -6 address`, `ip -6 route`,
   `resolvectl query -t AAAA asako.m.mado.moe`, and IPv6 connectivity with the
   proxy off. Verify IPv4 on an IPv4-only network as well.
4. Check `systemctl status traefik gateway-ipv6-config.timer`, then test an
   internal service over Tailscale IPv4, Tailscale IPv6, and loopback. Test an
   untrusted native IPv6 source remains denied. Check all four proxy modes using
   the existing operational procedure, including HK guard status.
5. If a profile was changed, restore the exported profile settings if needed.

Rollback by activating the previous NixOS generation (`nixos-rebuild switch
--rollback` or select the recorded generation). Restore any exported profile
backup separately; NixOS rollback does not revert NetworkManager profile edits.

## Baseline and validation status

The implementation checkout is on `kazuki`, where the existing host has a
global IPv6 address and RA default route on `vmbr0`; that confirms the shared
gateway's existing interface path. Read-only SSH to Asako was attempted but
denied because no key was accepted. Asako's active connection IPv6 methods,
resolver, Tailscale allocation, and proxy mode therefore remain unverified.
No live changes or deployment were made.
