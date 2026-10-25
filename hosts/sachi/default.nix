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
  my.services.regionalProxy.usExit = true;
  system.stateVersion = "22.05";
  imports = [
    ../modules/services/networking/ipv6
    ./hardware-configuration.nix
    ../common/baseline.nix
    ../common/boot-loader.nix
    ../common/users.nix
    ../common/trusted.nix
    ../modules/services/networking/regional-proxy
    ./samba
  ];

  environment.systemPackages = with pkgs; [
    deploy-rs
    nvidia-container-toolkit
    sing-box
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
      xrayPrivateKey = {
        owner = "sing-box";
        group = "sing-box";
      };
    } // optionalAttrs config.my.services.regionalProxy.usExit {
      regionalProxySocksUser = {
        sopsFile = ./regional-proxy-secrets.yaml;
        owner = "sing-box";
        group = "sing-box";
      };
      regionalProxySocksPassword = {
        sopsFile = ./regional-proxy-secrets.yaml;
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
              listen = "0.0.0.0";
              type = "vless";
              tag = "reality-main";
              listen_port = config.my.ports.xray.listen;
              users = [
                { name = "primary"; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; }
                { name = "makina"; uuid = config.sops.placeholder.makinaXrayClientId; flow = "xtls-rprx-vision"; }
              ];
              tls = { enabled = true; server_name = "www.cloudflare.com"; reality = {
                enabled = true;
                handshake = { server = "www.cloudflare.com"; server_port = 443; };
                private_key = config.sops.placeholder.xrayPrivateKey;
                short_id = "e5f60718";
              }; };
            }
            # Mobile-only SNI spoofing profile. Excluded from normal client routing.
            {
              listen = "0.0.0.0";
              type = "vless";
              tag = "reality-mobile";
              listen_port = config.my.ports.xray.mobileSachi;
              users = [
                { name = "primary"; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; }
                { name = "makina"; uuid = config.sops.placeholder.makinaXrayClientId; flow = "xtls-rprx-vision"; }
              ];
              tls = { enabled = true; server_name = "www.paypal.com"; reality = {
                enabled = true;
                handshake = { server = "www.paypal.com"; server_port = 443; };
                private_key = config.sops.placeholder.xrayPrivateKey;
                short_id = "27323628";
              }; };
            }
          ] ++ optional config.my.services.regionalProxy.usExit {
            type = "socks";
            tag = "regional-us-exit-socks";
            listen = "100.64.0.1";
            listen_port = 1080;
            users = [ {
              username = config.sops.placeholder.regionalProxySocksUser;
              password = config.sops.placeholder.regionalProxySocksPassword;
            } ];
          };
          outbounds = [
            {
              type = "direct";
            }
          ] ++ optional config.my.services.regionalProxy.usExit {
            type = "direct";
            tag = "regional-us-exit-uplink";
            # vmbr0 owns the host address and default route; enp13s0 is its L2 slave.
            bind_interface = brIf;
            inet4_bind_address = config.my.services.regionalProxy.usExitSourceIPv4;
            routing_mark = 1396785992;
            domain_resolver = {
              server = "local-dns";
              strategy = "ipv4_only";
            };
          };
          dns.servers = optionals config.my.services.regionalProxy.usExit [
            { type = "local"; tag = "local-dns"; }
          ];
          route.rules = optionals config.my.services.regionalProxy.usExit [
            {
              inbound = [ "regional-us-exit-socks" ];
              ip_version = 6;
              action = "reject";
            }
            {
              inbound = [ "regional-us-exit-socks" ];
              outbound = "regional-us-exit-uplink";
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
    ipv6AcceptRAConfig.Token = "static:::30";
    matchConfig.Name = brIf;
    address = [ hostIp ] ++ optional config.my.services.regionalProxy.usExit "${config.my.services.regionalProxy.usExitSourceIPv4}/24";
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
    enableIPv6 = true;
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
  my.services.ipv6Dns.enable = true;
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
  networking.firewall.allowedTCPPorts = [ config.my.ports.xray.listen config.my.ports.xray.mobileSachi ];
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
