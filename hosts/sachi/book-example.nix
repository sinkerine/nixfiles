{ ... }:
{
  services.nginx = {
    enable = true;
    virtualHosts."book-example.mado.moe" = {
      listen = [{ addr = "127.0.0.1"; port = 8098; }];
      root = "/var/www/book-example";
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers.book-example = {
      rule = "Host(`book-example.mado.moe`)";
      entryPoints = [ "websecure" ];
      middlewares = [ "wan@file" ];
      service = "book-example";
      tls.certResolver = "default";
    };
    services.book-example.loadBalancer.servers = [{
      url = "http://127.0.0.1:8098";
    }];
  };
}
