{ config, lib, ... }:
let
  cfg = config.my.services.loopx;
in {
  options.my.services.loopx = {
    enable = lib.mkEnableOption "LAN-only LoopX reverse proxy";
    domain = lib.mkOption { type = lib.types.str; };
    port = lib.mkOption { type = lib.types.port; default = 8767; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = config.my.services.gateway.enable;
      message = "LoopX requires the Traefik gateway and its LAN allowlist.";
    } ];
    users.users.sinkerine.linger = true;
    services.traefik.dynamicConfigOptions.http = {
      routers.loopx = {
        rule = "Host(`${cfg.domain}`)";
        entryPoints = [ "websecure" ];
        middlewares = [ "lan-only@file" ];
        service = "loopx";
      };
      services.loopx.loadBalancer.servers = [ {
        url = "http://127.0.0.1:${toString cfg.port}";
      } ];
    };
  };
}
