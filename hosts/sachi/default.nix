{
  config,
  pkgs,
  lib,
  mylib,
  hostname,
  ...
}:

with lib;

let
  wanIf = "enp13s0";
  brIf = "vmbr0";

  hostIp = "192.168.88.30/24";
  gateway = "192.168.88.1";

in
{
  system.stateVersion = "22.05";
  imports = [
    ./hardware-configuration.nix
    ../modules/services/networking/ipv6
    ../common/baseline.nix
    ../common/boot-loader.nix
    ../common/users.nix
    ../common/trusted.nix
    ../common/xray-sing-box-compat.nix
    ./samba
  ];

  environment.systemPackages = with pkgs; [
    deploy-rs
    nvidia-container-toolkit
    xray
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
      xrayPrivateKey = {
        owner = "xray";
        group = "xray";
      };
    };
    templates."xray.json" = {
      owner = "xray";
      group = "xray";
      content =
        let
          xrayClient = {
            id = config.sops.placeholder.xrayClientId;
            flow = "xtls-rprx-vision";
          };
          makinaXrayClient = {
            id = config.sops.placeholder.makinaXrayClientId;
            flow = "xtls-rprx-vision";
          };
        in
        builtins.toJSON {
          log.loglevel = "warning";
          inbounds = [
            {
              listen = "0.0.0.0";
              port = config.my.ports.xray.listen;
              protocol = "vless";
              settings = {
                clients = [ xrayClient makinaXrayClient ];
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
                  shortIds = [ "e5f60718" ];
                };
              };
            }
            # Mobile-only SNI spoofing profile. Excluded from normal client routing.
            {
              listen = "0.0.0.0";
              port = config.my.ports.xray.mobileSachi;
              protocol = "vless";
              settings = {
                clients = [ xrayClient makinaXrayClient ];
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
                  shortIds = [ "27323628" ];
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
      PermitRootLogin = "yes";
    };
  };

  users.users.root.hashedPasswordFile = config.sops.secrets.hashedPassword.path;
  users.users.sinkerine.linger = true;
  boot.kernelPackages = mkForce pkgs.linuxPackages_6_18;
  my.essentials.zfs = {
    enable = true;
    enableNonRootEncryption = true;
    enableZed = true;
    enableZfsUnstable = true;
    nonRootPools = [
      "main"
      "sub"
    ];
    encryptedZfsPath = "main";
  };
  networking.useDHCP = false;
  networking.networkmanager.enable = false;
  networking.firewall.enable = mkForce false;

  systemd.network.enable = true;

  # Bridged traffic does not need bridge netfilter on this host and the
  # extra hooks noticeably slow large LAN transfers such as SMB mounts.
  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 0;
    "net.bridge.bridge-nf-call-ip6tables" = 0;
    "net.bridge.bridge-nf-call-arptables" = 0;
  };

  systemd.network.netdevs."10-${brIf}" = {
    netdevConfig = {
      Name = brIf;
      Kind = "bridge";
    };
    bridgeConfig = {
      STP = false;
      ForwardDelaySec = 0;
    };
  };

  systemd.network.networks."10-${wanIf}" = {
    matchConfig.Name = wanIf;
    networkConfig = {
      Bridge = brIf;
      DHCP = "no";
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
  };

  systemd.network.networks."20-${brIf}" = {
    matchConfig.Name = brIf;
    address = [ hostIp ];
    networkConfig = {
      DHCP = "no";
      DNS = [ gateway ];
      IPv6AcceptRA = true;
      LinkLocalAddressing = "ipv6";
    };
    routes = [
      {
        Gateway = gateway;
        GatewayOnLink = true;
      }
    ];
  };
  # Load nvidia driver for Xorg and Wayland
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
    powerManagement.enable = false;
    open = false;
  };
  hardware.nvidia-container-toolkit.enable = true;

    ipv6AcceptRAConfig.Token = "static:::30";
  boot.kernelModules = [
    "coretemp"
    "kvm-intel"
  ];

  my.services.docker = {
    enable = true;
    serviceInit = {
      enable = true;
      rootDir = "/pool/main/docker";
      datasetRoot = "main/docker/available";
    };
  };
  my.services.zrepl = {
    enable = true;
    ports = { inherit (config.my.ports.zrepl.sachi) sink source; };
    openFirewallForPorts = [
      "sink"
      "source"
    ];
    configTemplateFile = ./zrepl/zrepl.yaml.jinja;
    sopsCertFile = ./zrepl/sachi.m.mado.moe.crt;
    sopsKeyFile = ./zrepl/sachi.m.mado.moe.key;
  };

  my.services.gateway = {
    enable = true;
    enableDocker = true;
    internalDomain = "${hostname}.m.mado.moe";
    externalDomain = "mado.moe";
    lanOnlyIpRanges = [
      config.my.ip.ranges.local
      config.my.ip.ranges.lan
      config.my.ip.ranges.wireguard
      config.my.ip.ranges.tailscale
      config.my.ip.ranges.docker
      config.my.ip.ranges.dockerRootless
    ];
  };
  services.traefik.dynamicConfigOptions.http.middlewares = mkIf config.my.services.gateway.enable {
    mastodon-auth-proxy.redirectRegex = {
      permanent = true;
      regex = "^https://mado.moe/\\.well-known/webfinger";
      replacement = "https://mastodon.mado.moe/.well-known/webfinger";
    };
  };
  my.services.headscale.enable = true;
  my.services.tailscale = {
    enable = true;
    useRoutingFeatures = "server";
  };
    enableIPv6 = true;
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
  my.services.ipv6Dns.enable = true;
  };
  networking.firewall.allowedTCPPorts = [
    config.my.ports.xray.listen
    config.my.ports.xray.mobileSachi
  ];
  my.services.proxmox = {
    enable = true;
    ipAddress = "192.168.88.30";
    bridges = [ "vmbr0" ];
    enableDashboardProxy = true;
    fakeSubscription = {
      enable = true;
      blockRemoteChecks = true;
    };
  };

  my.services.smartd.enable = true;
  my.services.ups.enable = true;
  my.services.metrics = {
    enable = true;
    enableScrapeHeadscale = true;
    enableScrapeSmartctl = true;
    enableScrapeNut = true;
  };
  my.services.monitoring = {
    enable = true;
    domain = "monitoring.${hostname}.m.mado.moe";
    datasourceHosts = [
      "sachi"
      "kazuki"
      "amane"
      "yumiko"
      "asako"
    ];
    dataDir = "/pool/main/appdata/grafana";
  };
  my.services.aria2 = {
    enable = true;
    package = pkgs.aria2-fast;
    maxConnectionPerServer = 128;
    downloadDir = "/pool/sub/download/aria2";
    enableSession = true;
    enableReverseProxy = true;
  };
  my.services.ariang = {
    enable = true;
    enableReverseProxy = true;
  };
  my.services.vsftpd = {
    enable = true;
    enableSsl = true;
    sopsCertFile = ./ftp/vsftpd.pem;
    sopsKeyFile = ./ftp/vsftpd.key;
  };

  services.udev.extraRules = ''
    # UDEV rules for 3d printer
    SUBSYSTEM=="tty", ATTRS{idVendor}=="2974", ATTRS{idProduct}=="0503", ACTION=="add", MODE:="0660", OWNER:="dockremap", GROUP:="dockremap", SYMLINK+="monoprice_3d_printer"
  '';
}
