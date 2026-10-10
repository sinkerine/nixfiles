{ config, lib, pkgs, ... }:
let
  cfg = config.my.services.ipv6Dns;
  settings = pkgs.writeText "cloudflare-ipv6.json" (builtins.toJSON {
    zone = "mado.moe";
    tokenFile = config.sops.secrets.cloudflare-ipv6-token.path;
    interface = "vmbr0";
    interfaceIdentifier = "::30";
    probeHostname = "headscale.mado.moe";
    publicRecords = [ { name = "mado.moe"; proxied = false; ttl = 1; } ];
    staticRecords = [
      { name = "sachi.m.mado.moe"; address = "fd7a:115c:a1e0::1"; }
      { name = "kazuki.m.mado.moe"; address = "fd7a:115c:a1e0::2"; }
      { name = "asako.m.mado.moe"; address = "fd7a:115c:a1e0::3"; }
      { name = "yumiko.m.mado.moe"; address = "fd7a:115c:a1e0::5"; }
    ];
  });
in {
  options.my.services.ipv6Dns.enable = lib.mkEnableOption "native IPv6 Cloudflare AAAA reconciliation";
  config = lib.mkIf cfg.enable {
    sops.secrets.cloudflare-ipv6-token = {
      sopsFile = ./secrets.yaml;
      key = "cloudflareDnsApiToken";
    };
    systemd.services.cloudflare-ipv6 = {
      description = "Reconcile native IPv6 Cloudflare DNS";
      after = [ "network-online.target" "traefik.service" ];
      wants = [ "network-online.target" ];
      path = [ pkgs.iproute2 pkgs.curl ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${./cloudflare.py} ${settings}";
        User = "root";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" "AF_NETLINK" ];
        TimeoutStartSec = 120;
      };
    };
    systemd.timers.cloudflare-ipv6 = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "2m";
        RandomizedDelaySec = "10s";
      };
    };
  };
}
