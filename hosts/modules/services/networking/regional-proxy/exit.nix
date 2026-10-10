{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf;
in
{
  config = mkIf config.my.services.regionalProxy.usExit {
    # sing-box marks only proxy-originated sockets; this rule makes those
    # sockets consult the physical routing table before any client TUN rule.
    systemd.services.regional-proxy-us-exit-route = {
      description = "Route US exit proxy sockets through Sachi uplink";
      wantedBy = [ "multi-user.target" ];
      before = [ "sing-box-server.service" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.iproute2 ];
      script = ''
        while ip rule del priority 100 fwmark 0x53414348/0xffffffff lookup main 2>/dev/null; do :; done
        ip rule add priority 100 fwmark 0x53414348/0xffffffff lookup main
      '';
      preStop = ''
        while ip rule del priority 100 fwmark 0x53414348/0xffffffff lookup main 2>/dev/null; do :; done
      '';
    };

    # Requires plus ordering makes a failed route-rule install stop sing-box
    # from starting with marked sockets able to escape through another route.
    systemd.services.sing-box-server = {
      requires = [ "regional-proxy-us-exit-route.service" ];
      after = [ "regional-proxy-us-exit-route.service" ];
      serviceConfig = {
        AmbientCapabilities = [ "CAP_NET_ADMIN" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" ];
      };
    };
  };
}
