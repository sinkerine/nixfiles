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
      ips = [ "172.31.241.1/30" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.regional-proxy-michiru-private-key.path;
      peers = [
        {
          publicKey = cfg.routerOsPeerPublicKey;
          allowedIPs = [ "172.31.241.2/32" ];
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
      for direction in -i -o; do
        iptables -t mangle -C FORWARD "$direction" wg-routeros -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
          iptables -t mangle -A FORWARD "$direction" wg-routeros -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
      done
    '';
    networking.firewall.extraStopCommands = ''
      for direction in -i -o; do
        iptables -t mangle -D FORWARD "$direction" wg-routeros -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
      done
    '';
    networking.nat = {
      enable = true;
      externalInterface = "eth0";
      internalInterfaces = [ "wg-routeros" ];
    };
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;

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
