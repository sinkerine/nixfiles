{ config, hostname, ... }:
{
  services.traefik.dynamicConfigOptions.http = {
    routers.paseo = {
      rule = "Host(`paeso.${hostname}.m.mado.moe`)";
      entryPoints = [ "websecure" ];
      tls.certResolver = "default";
      middlewares = [ "lan-only@file" ];
      service = "paseo";
    };
    services.paseo.loadBalancer.servers = [ { url = "http://127.0.0.1:6767"; } ];
  };
}
