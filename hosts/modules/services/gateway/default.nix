{ config, lib, mylib, pkgs, ... }:

with lib;
let
  cfg = config.my.services.gateway;
  inherit (mylib) mkDefaultTrueEnableOption assertNotNull;
  ipv6Base = pkgs.writeText "traefik-dynamic-base.json" (builtins.toJSON config.services.traefik.dynamicConfigOptions);
  ipv6ConfigCommand = "${pkgs.python3}/bin/python3 ${./ipv6-config.py} ${ipv6Base} ${config.services.traefik.dataDir}/dynamic-ipv6.yaml ${escapeShellArg (if cfg.ipv6Interface == null then "-" else cfg.ipv6Interface)} ${pkgs.iproute2}/bin/ip";
in {
  options.my.services.gateway = {
    enable = mkEnableOption "traefik gateway";
    enableDocker = mkEnableOption "docker integration";
    enableIPv6 = mkEnableOption "IPv6 gateway source ranges";
    ipv6Interface = mkOption {
      type = types.nullOr types.str;
      default = "vmbr0";
      description = "Optional explicitly trusted interface for dynamic native IPv6 gateway source ranges.";
    };
    enableDashboardProxy = mkDefaultTrueEnableOption "dashboard proxy";
    internalDomain = mkOption {
      type = with types; nullOr str;
      default = null;
      description = "domain for access inside the internal tailscale network";
    };
    externalDomain = mkOption {
      type = with types; nullOr str;
      default = null;
      description = "domain for access over the internet";
    };
    lanOnlyIpRanges = mkOption {
      type = with types; listOf str;
      default = [ config.my.ip.ranges.local ];
    };
    externalAllowListIpRanges = mkOption {
      type = with types; listOf str;
      default = config.my.ip.ranges.cloudFlareList
        ++ optionals cfg.enableIPv6 config.my.ip.ranges.cloudFlare6List;
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      networking.firewall.allowedTCPPorts = [ 80 443 ];
      sops.secrets.traefik-env = {
        format = "binary";
        sopsFile = ./traefik.env.txt;
        owner = "traefik";
      };
      services.traefik = {
        enable = true;
        staticConfigOptions = {
          log.level = "info";
          api = {
            dashboard = true;
            insecure = true;
          };
          entryPoints = {
            web = {
              address = ":80";
              http.redirections.entryPoint = {
                to = "websecure";
                scheme = "https";
                permanent = false;
              };
            };
            websecure = {
              address = ":443";
              http.tls.certResolver = "default";
            };
          };
          certificatesResolvers = {
            default = {
              acme = {
                email = "acme@15cm.net";
                storage = "${config.services.traefik.dataDir}/acme.json";
                dnsChallenge = {
                  provider = "cloudflare";
                  delayBeforeCheck = 5;
                  resolvers = [ "1.1.1.1:53" "8.8.8.8:53" ];
                };
              };
            };
          };
        };
        dynamicConfigOptions = {
          http = {
            middlewares = {
              # Tailscale clients have IPv4 and IPv6 overlay addresses. Keep
              # both addresses trusted by internal-only routes.
              lan-only.ipAllowList.sourceRange = cfg.lanOnlyIpRanges
                ++ [ config.my.ip.ranges.tailscale6 ]
                ++ optionals cfg.enableIPv6 [ config.my.ip.ranges.local6 ];
              wan.ipAllowList.sourceRange = cfg.lanOnlyIpRanges
                ++ optionals cfg.enableIPv6 [ config.my.ip.ranges.local6 config.my.ip.ranges.tailscale6 ]
                ++ cfg.externalAllowListIpRanges;
            };
          };
        };
      };

      systemd.services.traefik = {
        serviceConfig = {
          EnvironmentFile = [ config.sops.secrets.traefik-env.path ];
        };
      };
      users.users.traefik = { uid = config.my.ids.uids.traefik; };
      users.groups.traefik.gid = config.my.ids.uids.traefik;
    }
    (mkIf cfg.enableDocker {
      services.traefik.group = "docker";
      services.traefik.staticConfigOptions.providers = {
        docker = {
          watch = true;
          endpoint = "unix:///var/run/docker.sock";
          exposedbydefault = false;
          network = "g_proxy";
        };
      };
    })
    (mkIf cfg.enableIPv6 {
      services.traefik.dynamicConfigFile = "${config.services.traefik.dataDir}/dynamic-ipv6.yaml";
      systemd.services.traefik.serviceConfig.ExecStartPre = [ ipv6ConfigCommand ];
      systemd.services.gateway-ipv6-config = {
        description = "Refresh Traefik LAN IPv6 source ranges";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "traefik.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "traefik";
          ExecStart = ipv6ConfigCommand;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ config.services.traefik.dataDir ];
        };
      };
      systemd.timers.gateway-ipv6-config = {
        wantedBy = [ "timers.target" ];
        timerConfig = { OnBootSec = "1m"; OnUnitActiveSec = "1m"; };
      };
    })
    (mkIf cfg.enableDashboardProxy {
      services.traefik.dynamicConfigOptions.http = {
        routers.gatewayApi = {
          rule = "Host(`gateway.${assertNotNull cfg.internalDomain}`)";
          middlewares = [ "lan-only@file" ];
          service = "gatewayApi";
        };
        services = {
          gatewayApi.loadBalancer.servers = [{
            url = "http://127.0.0.1:${toString config.my.ports.gateway.listen}";
          }];
        };
      };
    })
  ]);

}
