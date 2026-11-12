{ config, lib, pkgs, ... }:

let
  cfg = config.my.services.regionalProxy;
  inherit (lib) mkIf mkOption types;
in
{
  options.my.services.regionalProxy.routerOsPeerPublicKey = mkOption {
    type = types.nullOr types.str;
    default = null;
    description = "RouterOS WireGuard public key for the HK peer.";
  };

  config = mkIf cfg.routerOsPeer {
    assertions = [
      {
        assertion = cfg.routerOsPeerPublicKey != null;
        message = "routerOsPeer requires routerOsPeerPublicKey.";
      }
    ];

    sops.secrets.regional-proxy-michiru-private-key = {
      sopsFile = ../../../../michiru/regional-proxy-secrets.yaml;
      key = "wireguardPrivateKey";
      owner = "root";
      group = "root";
      mode = "0400";
    };

    networking.wireguard.interfaces.wg-routeros = {
      ips = [ "172.31.241.1/30" "fd31:241::1/64" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.regional-proxy-michiru-private-key.path;
      peers = [
        {
          publicKey = cfg.routerOsPeerPublicKey;
          allowedIPs = [ "172.31.241.2/32" "fd31:241::2/128" ];
          persistentKeepalive = 25;
        }
      ];
    };
    networking.firewall.allowedUDPPorts = [ 51820 ];
    networking.firewall.interfaces.wg-routeros = {
      allowedUDPPorts = [ 53 ];
      allowedTCPPorts = [ 53 ];
    };
    # LAN clients advertise Ethernet MSS, but this path crosses a smaller
    # WireGuard link. Clamp both SYN directions to avoid PMTU black holes.
    networking.firewall.extraCommands = ''
      for tool in iptables ip6tables; do
        for direction in -i -o; do
          $tool -t mangle -C FORWARD "$direction" wg-routeros -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            $tool -t mangle -A FORWARD "$direction" wg-routeros -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        done
      done
    '';
    networking.firewall.extraStopCommands = ''
      for tool in iptables ip6tables; do
        for direction in -i -o; do
          $tool -t mangle -D FORWARD "$direction" wg-routeros -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        done
      done
    '';
    networking.nat = {
      enable = true;
      enableIPv6 = true;
      externalInterface = "eth0";
      internalInterfaces = [ "wg-routeros" ];
      internalIPv6s = [ "fd31:241::/64" ];
    };
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    # Michiru learns its IPv6 uplink using SLAAC even while forwarding.
    boot.kernel.sysctl."net.ipv6.conf.eth0.accept_ra" = 2;

    services.unbound = {
      enable = true;
      # Keep the host's resolver on the native uplink; this listener is only
      # reachable from RouterOS over wg-routeros.
      resolveLocalQueries = false;
      settings = {
        server = {
          interface = [ "172.31.241.1" ];
          access-control = [ "172.31.241.0/30 allow" ];
          do-ip4 = "yes";
          do-ip6 = "no";
          hide-identity = "yes";
          hide-version = "yes";
        };
        forward-zone = [
          {
            name = ".";
            forward-addr = [ "1.1.1.1" "1.0.0.1" ];
          }
        ];
      };
    };
  };
}
