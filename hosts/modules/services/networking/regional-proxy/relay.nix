{ config, lib, pkgs, ... }:

let
  cfg = config.my.services.regionalProxy;
  inherit (lib) mkIf;
  credentialDir = "/etc/regional-proxy/credentials";
  configPath = "/run/sing-box-hk-relay/config.json";
  singBoxConfig = builtins.toJSON {
    log.level = "warn";
    inbounds = [
      {
        type = "vless";
        tag = "public-reality";
        listen = "0.0.0.0";
        listen_port = 10087;
        users = [
          { name = "hk-direct"; uuid = "@HK_DIRECT_UUID@"; flow = "xtls-rprx-vision"; }
          { name = "us-exit"; uuid = "@US_EXIT_UUID@"; flow = "xtls-rprx-vision"; }
        ];
        tls = {
          enabled = true;
          server_name = "www.cloudflare.com";
          reality = {
            enabled = true;
            handshake = { server = "www.cloudflare.com"; server_port = 443; };
            private_key = "@REALITY_PRIVATE_KEY@";
            short_id = "@REALITY_SHORT_ID@";
          };
        };
      }
      {
        type = "socks";
        tag = "tailnet-socks";
        listen = "0.0.0.0";
        listen_port = 10088;
        bind_interface = "tailscale0";
        users = [ { username = "@TAILNET_SOCKS_USER@"; password = "@TAILNET_SOCKS_PASSWORD@"; } ];
      }
    ];
    outbounds = [
      { type = "direct"; tag = "hk-uplink"; }
      { type = "direct"; tag = "tailnet"; bind_interface = "tailscale0"; }
      {
        type = "socks";
        tag = "sachi-us-exit";
        server = "100.64.0.1";
        server_port = 1080;
        version = "5";
        username = "@SACHI_SOCKS_USER@";
        password = "@SACHI_SOCKS_PASSWORD@";
      }
    ];
    route = {
      rules = [
        { inbound = [ "public-reality" ]; auth_user = [ "hk-direct" ]; ip_cidr = [ "100.64.0.0/10" "fd7a:115c:a1e0::/48" ]; outbound = "tailnet"; }
        { inbound = [ "public-reality" ]; auth_user = [ "hk-direct" ]; outbound = "hk-uplink"; }
        { inbound = [ "public-reality" ]; auth_user = [ "us-exit" ]; outbound = "sachi-us-exit"; }
        { inbound = [ "tailnet-socks" ]; ip_cidr = [ "100.64.0.0/10" "fd7a:115c:a1e0::/48" ]; outbound = "tailnet"; }
        { inbound = [ "tailnet-socks" ]; outbound = "hk-uplink"; }
      ];
      final = "hk-uplink";
    };
  };
  templateFile = pkgs.writeText "sing-box-hk-relay-template.json" singBoxConfig;
  render = pkgs.writeShellScript "render-sing-box-hk-relay" ''
    install -d -m 0750 /run/sing-box-hk-relay
    ${pkgs.python3}/bin/python ${./render.py} ${templateFile} ${configPath} ${credentialDir}
    ${pkgs.sing-box}/bin/sing-box check -c ${configPath}
  '';
in
{
  config = mkIf cfg.hkRelay {
    assertions = [
      {
        assertion = pkgs.sing-box.version == "1.14.1";
        message = "HK relay requires sing-box 1.14.1";
      }
    ];

    environment.systemPackages = [ pkgs.sing-box ];
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "client";
      extraUpFlags = [ "--login-server=https://headscale.mado.moe" "--accept-dns=false" ];
      extraSetFlags = [ "--accept-dns=false" ];
    };
    users.users.sing-box = { isSystemUser = true; group = "sing-box"; };
    users.groups.sing-box = { };
    systemd.tmpfiles.rules = [ "d /run/sing-box-hk-relay 0750 sing-box sing-box - -" ];
    systemd.services.sing-box-hk-relay = {
      description = "Hong Kong VLESS Reality relay";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" "tailscaled.service" ];
      unitConfig.ConditionPathExists = "${credentialDir}/hk-direct-uuid";
      serviceConfig = {
        Type = "simple";
        User = "sing-box";
        Group = "sing-box";
        UMask = "0077";
        ExecStartPre = render;
        ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${configPath}";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ReadWritePaths = [ "/run/sing-box-hk-relay" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
    networking.firewall.allowedTCPPorts = [ 10087 ];
    networking.firewall.interfaces.tailscale0.allowedTCPPorts = [ 10088 ];
  };
}
