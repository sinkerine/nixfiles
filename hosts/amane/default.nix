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
    ../common/xray-sing-box-compat.nix
  ];

  sops = {
    defaultSopsFile = ./secrets.yaml;
    secrets = {
      hashedPassword.neededForUsers = true;
      xrayClientId = {
        owner = "xray";
        group = "xray";
      };
      makinaXrayClientId = {
        owner = "xray";
        group = "xray";
      };
      kazukiXrayClientId = {
        owner = "xray";
        group = "xray";
      };
      xrayPrivateKey = {
        owner = "xray";
        group = "xray";
      };
    };
    templates."xray.json" = {
      owner = "xray";
      group = "xray";
      content = builtins.toJSON {
        log.loglevel = "warning";
        inbounds = [
          {
            listen = "0.0.0.0";
            port = config.my.ports.xray.listen;
            protocol = "vless";
            settings = {
              clients = [
                {
                  id = config.sops.placeholder.xrayClientId;
                  flow = "xtls-rprx-vision";
                }
                {
                  id = config.sops.placeholder.makinaXrayClientId;
                  flow = "xtls-rprx-vision";
                }
                {
                  id = config.sops.placeholder.kazukiXrayClientId;
                  flow = "xtls-rprx-vision";
                }
              ];
              decryption = "none";
            };
            streamSettings = {
              network = "tcp";
              security = "reality";
              realitySettings = {
                show = false;
                dest = "www.cloudflare.com:443";
                xver = 0;
                serverNames = [ "www.cloudflare.com" ];
                privateKey = config.sops.placeholder.xrayPrivateKey;
                shortIds = [ "a1b2c3d4" ];
              };
            };
          }
          # Mobile-only SNI spoofing profile. Excluded from normal client routing.
          {
            listen = "0.0.0.0";
            port = config.my.ports.xray.mobileAmane;
            protocol = "vless";
            settings = {
              clients = [
                {
                  id = config.sops.placeholder.xrayClientId;
                  flow = "xtls-rprx-vision";
                }
                {
                  id = config.sops.placeholder.makinaXrayClientId;
                  flow = "xtls-rprx-vision";
                }
                {
                  id = config.sops.placeholder.kazukiXrayClientId;
                  flow = "xtls-rprx-vision";
                }
              ];
              decryption = "none";
            };
            streamSettings = {
              network = "tcp";
              security = "reality";
              realitySettings = {
                show = false;
                dest = "www.paypal.com:443";
                xver = 0;
                serverNames = [ "www.paypal.com" ];
                privateKey = config.sops.placeholder.xrayPrivateKey;
                shortIds = [ "8c614ced" ];
              };
            };
          }
        ];
        outbounds = [
          {
            protocol = "freedom";
          }
        ];
      };
      restartUnits = [ "xray.service" ];
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

  environment.systemPackages = with pkgs; [ xray ];

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
        # Coturn
        3478
        5349
      ];
      allowedUDPPorts = [
        # Coturn
        3478
        5349
      ];
      allowedUDPPortRanges = [
        # Coturn
        {
          from = 49160;
          to = 49200;
        }
      ];
    };
  };

  nix.gc.options = mkForce "-d";
    enableIPv6 = true;

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
  users.users.xray = {
    group = "xray";
    isSystemUser = true;
  };
  users.groups.xray = { };
  services.xray = {
    enable = true;
    settingsFile = config.sops.templates."xray.json".path;
  };
  systemd.services.xray.serviceConfig = {
    DynamicUser = mkForce false;
    User = "xray";
    Group = "xray";
  };
  my.services.gateway = {
    enable = true;
    enableDocker = true;
    internalDomain = "${hostname}.m.mado.moe";
    lanOnlyIpRanges = [
      config.my.ip.ranges.local
      config.my.ip.ranges.tailscale
    ];
  };
}
