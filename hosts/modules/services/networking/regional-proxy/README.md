# Regional proxy

`my.services.regionalProxy` exposes five opt-in role switches: `hkRelay`, `usExit`, `cnClient`, `routerOsPeer`, and `turn`. Asako and RouterOS retain runtime switches. The manual US domain allowlist is runtime profile data under `us_domains` in the Asako/Makina profile JSON, not a Nix option. Existing direct sing-box paths through Amane and Sachi remain available.

## Current setup

Status updated on 2026-10-09. The US-to-HK client module was removed from Kazuki and Sachi. The native RouterOS/WireGuard path is installed and ON after tunnel repair.

| Machine | Location / device | Configuration and status |
| --- | --- | --- |
| Kazuki | US home, NixOS | US-to-HK client removed; existing direct sing-box client remains available. |
| Sachi | US home, NixOS | US-to-HK client removed; residential SOCKS exit and direct sing-box server remain active. |
| Michiru | HK, NixOS VPS | Installed at `103.117.101.12`; HK relay, RouterOS WireGuard peer, and TURN active. |
| Asako | Nix-managed Linux laptop | `cnClient = true`; selects `off`, `amane`, `sachi`, or `hk` at runtime. HK path accepted for tested IPv4 traffic; selector currently OFF. |
| Makina | Android phone | Runs sing-box profiles generated from Asako's Nix-managed tooling; generation does not select or activate a profile. |
| Amane | JP, NixOS VPS | Existing direct sing-box server and applications; no new Michiru TCP/443 forwarding. |
| RouterOS | US home RB4011, main LAN gateway | Native regional WireGuard policy installed and ON; main-LAN HK/US and guest-US paths passed bounded live checks. |

Michiru management uses `ssh -i ~/.ssh/id_ed25519 root@103.117.101.12`. The `michiru` SSH alias points to this endpoint. The flake contains a system-only `deploy.nodes.michiru` target for this endpoint.

## Topology when enabled

```text
US main LAN: Kazuki, Sachi, other devices
  -> RouterOS (192.168.88.0/24)
     -> China matches: WireGuard over WAN -> Michiru -> HK Internet -> China
     -> other traffic: existing US WAN

CN: Asako / Makina sing-box
  -> China matches: local ISP
  -> VLESS REALITY -> Michiru (103.117.101.12)
     -> tailnet destinations: Tailscale -> target peer
     -> selected US destinations: Tailscale -> Sachi SOCKS -> US residential WAN
     -> other foreign destinations: HK Internet

Optional US host client
  -> China matches: Tailscale -> Michiru SOCKS -> HK Internet -> China
  -> tailnet: native Tailscale; other traffic: local US uplink

Existing direct sing-box paths -> Amane / Sachi remain available
```

The RouterOS path shares HK routing across the main LAN without requiring sing-box on every device. Guest LAN `192.168.89.0/24` is excluded.

### Stack and endpoints

Use sing-box 1.14.1 for REALITY ingress, client TUNs, and authenticated SOCKS; no separate HK Xray process is required. Headscale/Tailscale provides private peer connectivity, while a separate plain WireGuard tunnel serves RouterOS. NixOS/systemd manages services and persistent host routing/firewall rules; RouterOS scripts manage the LAN policy. SOPS stores credentials encrypted in Git and sops-nix decrypts them only at runtime.

| Endpoint | Purpose when enabled |
| --- | --- |
| Michiru public TCP/10087 | VLESS REALITY, separate `hk-direct` and `us-exit` identities |
| Michiru tailnet `100.64.0.11:10088` | Authenticated SOCKS for optional US host clients; current Michiru enrollment address |
| Sachi tailnet `100.64.0.1:1080` | Authenticated residential SOCKS exit |
| Michiru public UDP/51820 | RouterOS WireGuard peer |
| Michiru `172.31.241.1/30` | WireGuard address and Unbound DNS; RouterOS uses `172.31.241.2/30` |

Michiru's current enrolled tailnet address is `100.64.0.11`; the US-client SOCKS endpoint uses it. Sachi's `100.64.0.1` remains a configured address. Michiru uses `eth0` for its native uplink; proxy routing must preserve SSH and overlay underlay access.

HK-direct tailnet destinations use Tailscale; other HK-direct traffic uses Michiru's uplink. The US-exit identity selects Sachi's SOCKS service rather than a global Tailscale exit-node default route. Client rules classify destinations before choosing either identity; the relay does not independently classify countries. This avoids global exit-node policy routing on Michiru. Sachi's exit bypasses both its own optional client TUN and RouterOS HK classification.

## Android profile provisioning

Android HK profile generation is optional. Asako's generator reads `/etc/regional-proxy/asako-hk.json` when readable unless `MICHIRU_PROFILE_CONFIG_FILE` selects another path. Provision the default file as `root:sinkerine` with mode `0440` so both the Asako user generating profiles and the root HK TUN service can read it. Manage the profile input as a SOPS-encrypted Git secret decrypted to this runtime file; keep plaintext outside the Nix store; do not put them in Nix expressions or generated store paths. On Makina, select the generated profile in the profile selector; profile generation does not enable or select it automatically. Without a readable default file or explicit custom profile path, Amane and Sachi profile generation continues without HK credentials.

## Routing and DNS

The following describes behavior when the corresponding roles and profiles are enabled.

CN clients send China destinations direct to the local ISP, selected US destinations through Michiru and Sachi, and other foreign destinations through Michiru's HK uplink. CN tailnet traffic must pass through Michiru before reaching a peer, including while Asako's native Tailscale service is running.

The `mado.moe` apex and all subdomains bypass the Sachi US exit. Resolve normally: tailnet addresses go from Michiru to the matching peer over Tailscale; public addresses use Michiru's HK uplink. Apply this suffix rule before GeoIP-US rules, including for apps connecting by resolved IP. Keep DNS choices aligned with route choices. Protect proxy paths from loops with process/interface bypasses, IPv4-only proxy routes, and tailnet/loopback/link-local/LAN exclusions. Ordinary direct IPv6 remains available; proxy failures do not silently fall back to another exit.

Use China domain and IP rules for CN local-direct traffic. For US residential routing, GeoIP-US and explicit `us_domains` entries in the runtime Asako/Makina profile JSON are OR matches: either match routes through the US exit. The manual list is optional. Apply the `mado.moe` apex and suffix rule first; those destinations use HK-direct regardless of GeoIP-US or domain matches. Optional source: [blackmatrix7/ios_rule_script `USMedia.list`](https://github.com/blackmatrix7/ios_rule_script/blob/master/rule/Surge/USMedia/USMedia.list). It covers US media services, not every US website, and is not auto-enabled. Review and explicitly select entries in runtime profile JSON before adding them to `us_domains`.

## Implementation task boundaries

The concrete stack uses sing-box 1.14.1, VLESS REALITY, Tailscale, authenticated SOCKS, coturn, systemd, and NixOS firewall and `ip rule` configuration. Keep each work item within these non-overlapping boundaries:

| Task | File boundary or output |
| --- | --- |
| Shared module contract | `default.nix`: five opt-in role switches, all disabled by default. |
| Michiru relay | `relay.nix`, `render.py`, and `hosts/michiru/default.nix`: VLESS REALITY relay, Tailscale peer, authenticated SOCKS listener, runtime credentials, systemd service, firewall. |
| Sachi exit | `exit.nix` and `hosts/sachi/default.nix`: tailnet-only authenticated SOCKS; systemd-managed `ip rule` returns marked proxy sockets to physical routing table to avoid optional client TUN loop. |
| Asako laptop | `cn-client.nix`, `asako-hk.py`, and `hosts/asako/default.nix`, `hosts/asako/proxy-options.nix`, `hosts/asako/proxy-state.py`: China direct routing, HK relay, GeoIP-US/`us_domains` OR matching, `mado.moe` precedence, runtime TUN switch. |
| Makina Android | `hosts/makina/android-profiles.py` and `hosts/asako/test-android-profiles.py` only: optional generated sing-box profiles, runtime `us_domains` list, and matching route precedence; profile selection happens on Makina. |
| TURN | `turn.nix` only: coturn, ACME DNS challenge, systemd ordering, firewall. Configure runtime options `turnOptions.sharedSecretFile` (default `/run/secrets/matrix-turn-shared-secret`), `turnOptions.cloudflareTokenFile` (default `/run/secrets/cloudflare-turn-acme-token`), and required `turnOptions.publicIPv4`; keep secret values out of Nix. |
| RouterOS gateway | `routeros.nix`, `routeros/`, and this README: optional Michiru WireGuard peer, RouterOS allowlist/provisioning scripts, main-LAN HK route and DNS controls. |
| Integration | Review and evidence only: record credential/profile provisioning, DNS and routing checks, and Matrix call verification before moving TURN service. No host role or implementation file ownership. |

## TURN and remaining gates

The Michiru coturn role is opt-in through `turn = true`. It provides shared-secret TURN on 3478/UDP+TCP, TURN/TLS on 5349/TCP, and UDP relays on 49160–49200, using realm `turn.matrix.15cm.net` and configured `turnOptions.publicIPv4`. With `turnOptions.ipv6Interface` set, coturn discovers one stable global SLAAC address, writes explicit IPv4/IPv6 relay mappings, and falls back to IPv4 when IPv6 is unavailable or ambiguous. `turnOptions.ipv6Dns.enable` enables a two-minute Cloudflare reconciliation that owns only the marked AAAA record and refuses unmanaged duplicates. An address change withdraws the owned AAAA before coturn restart and republishes after service recovery; this interrupts active TURN allocations. Disable the timer and remove the marked AAAA to roll back while retaining IPv4 service.

Michiru's Headscale enrollment, relay credentials, Sachi residential exit, and RouterOS peer are active. RouterOS regional LAN policy is installed; see the current setup above for its last recorded state. Remaining regional acceptance needs a routed global-IPv6 vantage, genuine CN-ISP coverage, and Makina device verification when the user resumes it. From a genuine CN ISP, verify direct China traffic, HK and US egress, home-domain and resolved-IP routing, tailnet access with native Tailscale present, and selected-path failure/recovery. Makina still needs source-generated profile startup, manual `us_domains` routing, DNS/home/tailnet routing, and failure/recovery checks. Asako's tested IPv4 Matrix, manual-US domain, and LAN `media.mado.moe` paths passed; native IPv6 Matrix also failed its baseline. Synapse's TLS TURN URI migration remains unperformed. These historical results do not establish current runtime state. Michiru does not forward TCP/443 to Amane; other public HTTPS services remain on their current hosts.

## RouterOS main-LAN Hong Kong route

Michiru's `my.services.regionalProxy.routerOsPeer` role is opt-in and remains `false` by default in the shared module. Michiru enables it and uses its own SOPS key at `/run/secrets/regional-proxy-michiru-private-key`; its peer address is `172.31.241.1/30`, listening on UDP 51820. RouterOS uses a separate `wg-regional-hk` key and `172.31.241.2/30`. The existing RouterOS `wireguard1` interface and `192.168.100.0/24` route are untouched. Michiru performs HK-uplink source NAT for tunnel traffic and runs Unbound at `172.31.241.1`, forwarding queries to `1.1.1.1` and `1.0.0.1` over its ordinary HK uplink. This route never uses Sachi's residential SOCKS exit.

RouterOS was upgraded from 7.12.1 to 7.24.5 (stable), verified over SSH on 2026-10-07, on an RB4011; the main LAN is `192.168.88.0/24` on `bridge_lan`, guest is `192.168.89.0/24` on `bridge_vlan2`, WAN is `sfp-sfpplus1`, public WAN is `45.30.94.38`, DNS upstream is `8.8.8.8`, and the default FastTrack rule is `defconf: fasttrack`. Provisioning requires RouterOS 7.16.0 or newer and refuses older versions before secrets, upload, or import. Current 7.24.5 satisfies this gate; validate DNS static FWD/address-list TTL behavior before activation. Provisioning also requires existing `/ip dns allow-remote-requests` enabled; it reads and asserts the value, never changes it.

Generated importer owns only entries marked `regional-hk-owned`. Import creates disabled routes, WireGuard objects, DNS forwards, address lists, firewall/NAT/mangle rules, toggle scripts, and a persistent state script containing the pre-install FastTrack matcher and main-LAN DHCP DNS baseline; no traffic changes until an operator runs `regional-hk-on`. Repeated `on` does not overwrite that baseline, and `off` restores it after RouterOS reboot. The main LAN alone gets DHCP DNS `192.168.88.1` and conventional external UDP/TCP 53 redirection. Guest DNS, guest routing, and WAN port-forwarded sessions are excluded. On activation, owned IPv4 mangle and DNS redirect rules are enabled and DNS cache is flushed. Native IPv6 routing is independent of the regional policy. The regional policy is imported and currently ON. Main-LAN HK/US routing, selected-path failure and recovery, and reboot-while-ON restoration passed live acceptance. The 2.4 GHz guest AP now has both `wlan_guest_2g` and `vlan2-2g` on `bridge_vlan2`; guest DHCP explicitly advertises `8.8.8.8` because guest access to RouterOS DNS at `192.168.89.1` is blocked by the input firewall. Same-destination main-HK/guest-US egress and guest DNS preservation during ON passed. Native global IPv6 egress remains unverified without a client route.

RouterOS HK routing uses only an explicit domain allowlist in `routeros/domains.txt`; it starts empty, so no LAN destinations are classified until an operator adds domains and runs `routeros/provision.sh allowlist`. Each entry includes its subdomains and is resolved through Michiru's DNS. GeoIP and generated China IP/domain lists are not used. Resolved addresses are shared by IP, so another hostname on the same CDN address can follow the allowlisted route. DoH, DoT, VPN apps, and hardcoded resolver protocols can bypass conventional port 53 rules. IPv6 uses native ISP routing on both LANs and bypasses HK classification. Allowlisted IPv4 traffic fails closed through the tunnel when HK is unreachable; `off` returns new traffic to the existing US WAN and removes only regional marked connections.

RouterOS keeps `address-list-extra-time=0s`, so dynamic allowlist IP memberships follow DNS answer TTLs until the answer TTL expires.

Sachi's residential exit uses a dedicated `192.168.88.31` source on `vmbr0`, bound only on the `regional-us-exit-uplink` direct outbound when `usExit` is enabled. It resolves hostnames IPv4-only and rejects IPv6 SOCKS destinations, including literal IPv6 addresses. The service receives `CAP_NET_ADMIN` in its ambient and bounding sets so sing-box can set `SO_MARK`. RouterOS returns `.31` before CN classification, keeping exit traffic on US WAN even for CN IPs and shared CDNs; ordinary `.30` traffic remains eligible for existing client routing and RouterOS HK routing. `.31` is outside the current DHCP pool (`.50`–`.254`) and has no lease; check for duplicate/static assignments before activating the exit. Change the `usExitSourceIPv4` Nix option and `REGIONAL_PROXY_USEXIT_SOURCE_IPV4` provisioning setting together if the reserved address changes.

Measured HK routing was slower than direct WAN for the tested China sites. Experimental Bilibili CDN bypass rules were rolled back because routing validation failed and CDN selection did not give a repeatable speed improvement.

### Preventing the HK–US exit routing loop

A CN client can select the US exit for a domain whose resolved IP also matches RouterOS's China rules. Without an exemption, Sachi's connection would go back to HK instead of leaving through the US WAN:

```text
CN client -> Michiru -> Sachi US exit -> RouterOS
                                          -> Michiru -> RouterOS -> Michiru -> ...
```

The dedicated source address distinguishes proxy exit connections from normal Sachi traffic. Here, `.31` means the full LAN address `192.168.88.31`, not a destination address or the public US exit IP. Sachi binds connections opened by its residential SOCKS outbound to this extra address on `vmbr0`; it is assigned only while `usExit` is enabled.

| Source IP seen by RouterOS | Purpose | Routing behavior |
| --- | --- | --- |
| `192.168.88.30` | Normal Sachi connections | China matches remain eligible for HK routing. |
| `192.168.88.31` | Connections opened by Sachi's residential proxy exit | Exempted before China classification; use the existing US WAN. |

Two protections work together:

1. On Sachi, socket mark `0x53414348` and priority-100 `ip rule` select the main routing table before client TUN rules. This prevents the exit from entering Sachi's own optional proxy client.
2. On RouterOS, the `.31` source exemption precedes China route marking. This prevents the router from sending the exit connection back to Michiru, even when its destination is a China IP or shared CDN address.

```text
CN client -> Michiru -> Sachi SOCKS
                         -> source 192.168.88.31 -> RouterOS -> US WAN -> destination
```

RouterOS later translates the LAN source to the residential public IP. Michiru selects Sachi through an authenticated SOCKS outbound, not a global Tailscale exit-node default route.

Home-service protection is separate: `mado.moe` and its subdomains, including `media.mado.moe`, bypass the Sachi US exit, and RouterOS excludes the home WAN endpoint from HK classification. This keeps access to home services from recirculating through the residential exit.

These protections are implemented but not yet verified with live regional traffic. Before activation, confirm `.31` has no duplicate assignment, the Sachi outbound uses `.31`, its marked sockets select the main table, and the RouterOS source exemption appears before China marking rules. Test a China-IP destination through the US-exit identity and confirm it leaves through US WAN without returning to HK. Keep `usExitSourceIPv4` and `REGIONAL_PROXY_USEXIT_SOURCE_IPV4` synchronized if the address changes.

Headscale is the private mesh control plane for enrollment and peer configuration. It does not carry ordinary traffic; Tailscale sends peer traffic directly when possible and uses DERP only when a direct path is unavailable. Control-plane location affects enrollment/configuration, while DERP path affects relayed peer latency. Neither changes the RouterOS CN-to-HK Internet path. Asako's laptop and Makina's generated sing-box profile remain optional; routine LAN HK routing is handled by RouterOS.

### Domain allowlist

The RouterOS policy does not consume SagerNet geosite or geoip rule sets. Maintain the explicit list in `routeros/domains.txt` and render it with:

```sh
routeros/update-sources.sh /tmp/regional-hk-lists.rsc
python3 routeros/test_routeros.py
```

`update-sources.sh` is a compatibility entrypoint for `allowlist.py`; it renders local domain entries without fetching remote rule sets. Apply changes with `routeros/provision.sh allowlist`. Asako/Makina sing-box client profiles use their own remote SagerNet rule sets independently of this RouterOS allowlist.

### SOPS and operator provisioning

WireGuard keys and shared SOCKS credentials are stored in these encrypted Git files:

| Encrypted file | Recipients | Purpose |
| --- | --- | --- |
| `hosts/michiru/regional-proxy-secrets.yaml` | Michiru host age recipient and Kazuki recovery age recipient | Michiru peer private key; sops-nix decrypts to root-readable runtime file. |
| `hosts/modules/services/networking/regional-proxy/routeros/routeros-secrets.yaml` | Kazuki recovery age recipient | RouterOS peer private key; decrypted only on the authorized admin machine during explicit provisioning. |
| `hosts/sachi/regional-proxy-secrets.yaml` | Sachi and Michiru host age recipients, plus Kazuki recovery age recipient | Shared residential SOCKS username/password; Sachi consumes when `usExit` is enabled, Michiru provisions the matching runtime files. |

New files use scoped age-only SOPS rules. The configured administrator PGP key is expired and unusable for encryption; existing PGP rules and keys were left unchanged. Keep `/keys/age/kazuki.txt` available for recovery and use `sops --extract` only into a mode-0600 runtime file. `hosts/michiru/routeros-peer.pub` and `hosts/michiru/routeros-public.pub` contain public keys only. The existing RouterOS `wireguard1` key is not rotated here; any exposed-key rotation is separate coordinated maintenance.

Sachi and Michiru consume the same encrypted SOCKS file, with no duplicated credential values. Michiru uses `/etc/ssh/ssh_host_ed25519_key` through sops-nix to decrypt it. Runtime mapping:

| SOPS key | Michiru runtime secret | Relay credential symlink |
| --- | --- | --- |
| `regionalProxySocksUser` | `/run/secrets/regionalProxySocksUser` | `/etc/regional-proxy/credentials/sachi-socks-user` |
| `regionalProxySocksPassword` | `/run/secrets/regionalProxySocksPassword` | `/etc/regional-proxy/credentials/sachi-socks-password` |

Both targets are mode `0400`, owned by `root:root` while `hkRelay` is off and by `sing-box:sing-box` when enabled. The credential directory is mode `0750` with the corresponding group. Credential changes restart `sing-box-hk-relay.service` only when enabled.

The relay renderer requires eight files in `/etc/regional-proxy/credentials`. Michiru provisions `sachi-socks-user` and `sachi-socks-password` from Sachi's shared encrypted file, and `hk-direct-uuid`, `us-exit-uuid`, `reality-private-key`, `reality-short-id`, `tailnet-socks-user`, and `tailnet-socks-password` from `hosts/michiru/relay-secrets.yaml`. SOPS exposes runtime files readable by the relay; never embed plaintext in Nix expressions or store outputs. Optional US host clients need the matching `tailnet-socks-user` and `tailnet-socks-password` in their configured credential directory. Asako/Makina require matching REALITY public parameters and client identities in their runtime profile input.

Prerequisites: Michiru installed and reachable by SSH; RouterOS 7.16.0 or newer reachable as the configured `router` alias with DNS requests already enabled; encrypted Michiru and RouterOS files decryptable on Kazuki; Michiru public endpoint and UDP 51820 reachable; operator account permitted to upload/import RouterOS files. Current RouterOS 7.24.5 satisfies the version gate. Install the disabled configuration, then explicitly toggle it:

```sh
routeros/provision.sh install
routeros/provision.sh status
routeros/provision.sh on
routeros/provision.sh off
```

`install` checks RouterOS version and DNS state before SOPS, renders secret-bearing RSC only in a private `/run` directory, uploads it for one import, then removes local and remote temporary files on success or failure. It verifies the empty allowlist baseline, 16 owned address-list entries, 2 owned DNS static entries, and no regional IPv6 block. Run `allowlist` after editing `domains.txt` to replace the RouterOS domain entries safely; it clears old marked sessions and flushes DNS cache. `on` enables DNS, IPv4 routing, and NAT; `off` disables them and removes only marked regional connections. Existing scripts and entries from other tasks are not deleted.

To roll back, run `routeros/provision.sh off`; then, after confirming no references remain, remove only objects tagged `regional-hk-owned`, the four `regional-hk-*` scripts (including persistent state), and the `hk-cn` routing table. Do not remove or rotate `wireguard1`. Generated command ordering and cleanup have local static/mocked coverage; historical live acceptance and remaining gaps are summarized above.

## Runtime controls and validation

Commands below are operator steps for a provisioned setup, not evidence of completed activation. Run `routeros/` commands from this module directory.

```sh
# Asako: select a path or stop the TUN
asako-proxy status
asako-proxy hk
asako-proxy off
# Existing direct profiles
asako-proxy amane
asako-proxy sachi

# Kazuki / Sachi: the US-to-HK client module is removed; use RouterOS policy
# or an existing direct profile for regional routing.
```

Asako's HK selection installs policy rules for both tailnet IPv4 and IPv6 ahead of native Tailscale routes. A blackhole guard remains while HK is selected, so a stopped/failed HK TUN cannot silently restore direct peer access. Switching off or selecting an existing direct profile removes the HK policy. Makina selects its generated profile in Android sing-box.

Inspect the affected host after activation:

```sh
ip -4 rule show
ip -6 rule show
ip -4 route show table all
ip -6 route show table all
sudo nft list ruleset
tailscale status
tailscale ping <peer-name-or-address>
systemctl status sing-box-hk-relay.service  # Michiru
systemctl status regional-proxy-us-exit-route.service sing-box-server.service  # Sachi
```

Use `tailscale ping` to inspect peer connectivity, not to prove that application traffic passed through the HK proxy. Check application paths separately with `curl`, `dig`, and service logs. `mtr`, `traceroute`, or `nexttrace` can inspect underlay reachability; their hop lists do not reveal every SOCKS/REALITY hop.

| Path / test | Expected result |
| --- | --- |
| CN client: China domain and literal China IPv4 | Local ISP; compare DNS and HTTP results with HK TUN on/off. |
| CN client: generic foreign site | HK public egress. |
| CN client: selected US domain or US IPv4 | US residential egress through Sachi. |
| CN client: tailnet HTTP service | Reached through Michiru; HK failure blocks access while HK remains selected. |
| CN client: `https://media.mado.moe` | Home service reachable through HK-direct/public or tailnet path; no Sachi exit loop. |
| US host client: China / global / tailnet | HK / US WAN / native tailnet respectively. |
| RouterOS main LAN: CN domain and CN IPv4 | HK egress; `dig @192.168.88.1 baidu.com` exercises domain classification. |
| RouterOS main LAN: other sites; guest LAN | Existing US WAN; guest DNS/routing unchanged. |
| Sachi exit to China IP or shared CDN | Source `.31` remains on US WAN; no return to HK. |
| IPv6 while RouterOS route is on | Native ISP egress; independent of regional IPv4 routing. |
| HK or Sachi unavailable | Affected proxy path fails without an automatic alternate exit; local China-direct path remains available. |
| RouterOS toggle-off rollback | While enabled, run `off`; compare main-LAN DHCP DNS and FastTrack matcher byte-for-byte with the pre-import baseline, verify guest DHCP unchanged, regional rules disabled, marked connections removed, and new traffic on existing WAN. |
| RouterOS persistence acceptance | With regional routing enabled and baseline state captured, reboot RouterOS; verify it returns enabled with state intact, then run `off` and prove saved main-LAN DHCP DNS and FastTrack matcher are restored exactly. Verify guest DHCP unchanged, regional rules inactive, marked connections removed, existing-WAN routing, and management access. Reboot-while-off does not prove persistent baseline restoration and is insufficient. |
| TURN, if enabled later | STUN/TURN reachability and real Matrix media verified before moving service from Amane. |

For egress checks, use `curl https://api.ipify.org` with a controlled test profile or rule that selects the desired outbound; that site's own category is not proof of every route. Test DNS answers and resolved-IP requests as well as domain requests, including `mado.moe`, to catch route mismatches and loops. Do not include secret file contents in validation logs.

For RouterOS HK classifier acceptance, use `https://api4.ipify.org` as the IPv4 echo endpoint: it returns the observed client address as plain text. The production China-domain list does not need to include this test hostname. During an explicitly coordinated test window, add a temporary RouterOS DNS FWD entry for `api4.ipify.org` forwarding to the HK DNS listener and writing answers to `regional-hk-cn`; query it through RouterOS from the actual LAN client so DNS-derived addresses enter the same classifier as production domains. Save a current A answer, verify its exact dynamic-list membership and remaining timeout, then pin each HTTPS request to that freshly selected IP with `curl --resolve` while keeping the hostname for TLS/SNI. Never reuse a pinned CDN address across runs. Require a successful HTTP status and a valid IPv4 echo before accepting an egress result. Check answer membership before the ON baseline and immediately before peer disable. DNS-derived entries expire with answer TTL; do not refresh DNS during peer fault. Keep the echo body in a private temporary file and report only parsed status/address. Remove the temporary FWD entry after restoring policy OFF, then verify no test-created dynamic rows remain; let TTL expire rather than broadly deleting rows whose source is uncertain. Use an independent US echo endpoint (for example `https://ident.me`) as the concurrent control. Retire `myip.ipip.net` from proxy monitoring: it returned HTTP 521 directly from Michiru during the 2026-10-08 acceptance work, independently of the proxy route.
