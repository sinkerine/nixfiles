{
  config,
  pkgs,
  lib,
  mylib,
  hostname,
  ...
}:

with lib;

{
  system.stateVersion = "22.05";
  imports = [
    ./hardware-configuration.nix
    ../common/baseline.nix
    ../common/users.nix
    ../common/grub-legacy.nix
  ];

  sops = {
    defaultSopsFile = ./secrets.yaml;
    secrets = {
      hashedPassword.neededForUsers = true;
      xrayClientId = {
        owner = "sing-box";
        group = "sing-box";
      };
      makinaXrayClientId = {
        owner = "sing-box";
        group = "sing-box";
      };
      kazukiXrayClientId = {
        owner = "sing-box";
        group = "sing-box";
      };
      xrayPrivateKey = {
        owner = "sing-box";
        group = "sing-box";
      };
    };
    templates."sing-box-server.json" = {
      owner = "sing-box";
      group = "sing-box";
      content = builtins.toJSON {
          log.level = "warn";
          inbounds = [
            {
              type = "vless";
              tag = "reality-main";
              listen = "0.0.0.0";
              listen_port = config.my.ports.xray.listen;
              users = [
                { name = "primary"; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; }
                { name = "makina"; uuid = config.sops.placeholder.makinaXrayClientId; flow = "xtls-rprx-vision"; }
                { name = "kazuki"; uuid = config.sops.placeholder.kazukiXrayClientId; flow = "xtls-rprx-vision"; }
              ];
              tls = {
                enabled = true;
                server_name = "www.cloudflare.com";
                reality = {
                  enabled = true;
                  handshake = { server = "www.cloudflare.com"; server_port = 443; };
                  private_key = config.sops.placeholder.xrayPrivateKey;
                  short_id = "a1b2c3d4";
                };
              };
            }
          # Mobile-only SNI spoofing profile. Excluded from normal client routing.
            {
              type = "vless";
              tag = "reality-mobile";
              listen = "0.0.0.0";
              listen_port = config.my.ports.xray.mobileAmane;
              users = [
                { name = "primary"; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; }
                { name = "makina"; uuid = config.sops.placeholder.makinaXrayClientId; flow = "xtls-rprx-vision"; }
                { name = "kazuki"; uuid = config.sops.placeholder.kazukiXrayClientId; flow = "xtls-rprx-vision"; }
              ];
              tls = {
                enabled = true;
                server_name = "www.paypal.com";
                reality = {
                  enabled = true;
                  handshake = { server = "www.paypal.com"; server_port = 443; };
                  private_key = config.sops.placeholder.xrayPrivateKey;
                  short_id = "8c614ced";
                };
              };
            }
          ];
          outbounds = [
            {
              type = "direct";
            }
          ];
        };
      restartUnits = [ "sing-box-server.service" ];
    };
    age = {
      keyFile = "/keys/age/${hostname}.txt";
      sshKeyPaths = [ ];
    };
    # https://github.com/Mic92/sops-nix/issues/167
    gnupg.sshKeyPaths = [ ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  environment.systemPackages = with pkgs; [ sing-box ];

  users.users.sinkerine.linger = true;

  boot.kernelPackages = mkForce pkgs.linuxPackages_6_18;
  my.essentials.zfs = {
    enable = true;
    enableNonRootEncryption = true;
    enableZed = true;
    enableZfsUnstable = true;
    nonRootPools = [ "tank" ];
    encryptedZfsPath = "tank/encrypted";
  };

  networking = {
    hostName = hostname;
    domain = "15cm.net";
    useDHCP = true;
    firewall = {
      allowedTCPPorts = [
        config.my.ports.xray.listen
        config.my.ports.xray.mobileAmane
      ];
    };
  };

  nix.gc.options = mkForce "-d";

  my.services.zrepl = {
    enable = true;
    ports = { inherit (config.my.ports.zrepl.amane) push; };
    configTemplateFile = ./zrepl/zrepl.yaml.jinja;
    sopsCertFile = ./zrepl/amane.m.mado.moe.crt;
    sopsKeyFile = ./zrepl/amane.m.mado.moe.key;
  };
  my.services.docker = {
    enable = true;
    serviceInit = {
      enable = true;
      rootDir = "/pool/tank/docker";
      datasetRoot = "tank/encrypted/docker/available";
    };
  };
  my.services.metrics.enable = true;
  my.services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };
  users.users.sing-box = { isSystemUser = true; group = "sing-box"; };
  users.groups.sing-box = { };
  systemd.services.sing-box-server = {
    description = "VLESS Reality proxy server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${config.sops.templates."sing-box-server.json".path}";
      Restart = "on-failure";
      RestartSec = 5;
      User = "sing-box";
      Group = "sing-box";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
  my.services.gateway = {
    enable = true;
    enableIPv6 = true;
    enableDocker = true;
    internalDomain = "${hostname}.m.mado.moe";
    lanOnlyIpRanges = [
      config.my.ip.ranges.local
      config.my.ip.ranges.tailscale
    ];
  };
}
