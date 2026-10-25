{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.my.services.mahjong;
  app = pkgs.runCommand "mahjong-scoreboard" { } ''
    mkdir -p $out
    cp ${./server.py} $out/server.py
    cp ${./index.html} $out/index.html
  '';
in
{
  options.my.services.mahjong = {
    enable = mkEnableOption "riichi mahjong scoreboard";
    enableReverseProxy = mkEnableOption "mahjong scoreboard reverse proxy";
    port = mkOption {
      type = types.int;
      default = 3020;
    };
    hostName = mkOption {
      type = types.str;
      default = "ricchi.mado.moe";
      description = "Public hostname exposed through traefik.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      systemd.services.mahjong = {
        description = "Riichi mahjong scoreboard";
        wantedBy = [ "multi-user.target" ];
        environment = {
          MAHJONG_HOST = "127.0.0.1";
          MAHJONG_PORT = toString cfg.port;
        };
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${app}/server.py";
          DynamicUser = true;
          StateDirectory = "mahjong";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          Restart = "on-failure";
        };
      };
    }
    (mkIf (cfg.enableReverseProxy && config.my.services.gateway.enable) {
      services.traefik.dynamicConfigOptions.http.routers.mahjong = {
        rule = "Host(`${cfg.hostName}`)";
        service = "mahjong";
      };
      services.traefik.dynamicConfigOptions.http.services.mahjong.loadBalancer.servers = [
        {
          url = "http://127.0.0.1:${toString cfg.port}";
        }
      ];
    })
  ]);
}
