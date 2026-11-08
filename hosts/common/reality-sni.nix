{ config, lib, ... }:

let
  targets = builtins.fromJSON (builtins.readFile ./reality-sni-targets.json);
  domains = lib.mapAttrsToList (_: target: target.domain) targets;
  ports = lib.mapAttrsToList (_: target: target.listen_port) targets;
in
{
  assertions = [
    {
      assertion = lib.all (name: name != "normal"
        && builtins.match "[a-z0-9]+(-[a-z0-9]+)*" name != null) (builtins.attrNames targets)
        && lib.all (domain: builtins.match "[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*" domain != null) domains;
      message = "REALITY SNI targets need safe profile names (normal is reserved) and DNS hostnames.";
    }
    {
      assertion = builtins.length domains == builtins.length (lib.unique domains);
      message = "REALITY SNI targets must have unique domains.";
    }
    {
      assertion = builtins.length ports == builtins.length (lib.unique ports)
        && lib.all (port: builtins.isInt port && port >= 1024 && port <= 65535) ports;
      message = "REALITY SNI targets must have unique unprivileged listener ports.";
    }
  ];

  services.traefik.dynamicConfigOptions.tcp = {
    routers = lib.mapAttrs (name: target: {
      entryPoints = [ "websecure" ];
      rule = "HostSNI(`${target.domain}`)";
      service = "reality-${name}";
      tls.passthrough = true;
    }) targets;
    services = lib.mapAttrs' (name: target: lib.nameValuePair "reality-${name}" {
      loadBalancer.servers = [ { address = "127.0.0.1:${toString target.listen_port}"; } ];
    }) targets;
  };
}
