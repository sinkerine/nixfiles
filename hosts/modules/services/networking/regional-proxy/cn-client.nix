{ config, lib, pkgs, ... }:

let
  cfg = config.my.services.regionalProxy;
in
{
  systemd.services.sing-box-hk-tun = lib.mkIf cfg.cnClient {
    description = "Asako Hong Kong sing-box TUN routing";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "simple";
      RuntimeDirectory = "asako-hk";
      RuntimeDirectoryMode = "0700";
      ExecStartPre = "${pkgs.python3}/bin/python ${./asako-hk.py} ${config.sops.templates."asako-hk.json".path} /run/asako-hk/config.json ${../../../../makina/android-profiles.py}";
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c /run/asako-hk/config.json";
      Restart = "on-failure";
      RestartSec = "3s";
      User = "root";
      CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
      NoNewPrivileges = true;
    };
  };
}
