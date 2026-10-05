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
  wanIf = "enp22s0";
  brIf = "vmbr0";

  hostIp = "192.168.88.29/24";
  gateway = "192.168.88.1";
in
{
  system.stateVersion = "22.05";
  imports = [
    ./hardware-configuration.nix
    ../common/baseline.nix
    ../common/boot-loader.nix
    ../common/users.nix
    ../common/trusted.nix
  ];

  environment.systemPackages = with pkgs; [
    easyrsa
    herdr
    i2c-tools
    sing-box
  ];

  sops = {
    defaultSopsFile = ./secrets.yaml;
    secrets = {
      hashedPassword.neededForUsers = true;
      amaneXrayClientId = {
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
    templates."sing-box-proxy.json" = {
      owner = "sing-box";
      group = "sing-box";
      mode = "0400";
      content = builtins.toJSON {
        log.level = "warn";
        inbounds = [
          {
            type = "socks";
            tag = "socks-in";
            listen = "127.0.0.1";
            listen_port = 10809;
          }
        ];
        outbounds = [
          {
            type = "vless";
            tag = "amane";
            server = "direct.15cm.net";
            server_port = config.my.ports.xray.listen;
            uuid = config.sops.placeholder.amaneXrayClientId;
            flow = "xtls-rprx-vision";
            tls = {
              enabled = true;
              server_name = "www.cloudflare.com";
              utls = {
                enabled = true;
                fingerprint = "chrome";
              };
              reality = {
                enabled = true;
                public_key = "IM4pgDQbcql0ZIrzUWeU0HKE8GWbqsAV1t3c-PC20ks";
                short_id = "a1b2c3d4";
              };
            };
          }
        ];
        route.final = "amane";
      };
      restartUnits = [ "sing-box-proxy.service" ];
    };
    age = {
      keyFile = "/keys/age/${hostname}.txt";
      sshKeyPaths = [ ];
    };
    # https://github.com/Mic92/sops-nix/issues/167
    gnupg.sshKeyPaths = [ ];
  };

  users.users.root.hashedPasswordFile = config.sops.secrets.hashedPassword.path;

  users.users.sing-box = {
    group = "sing-box";
    isSystemUser = true;
  };
  users.groups.sing-box = { };

  systemd.services.sing-box-proxy = {
    description = "Amane SOCKS5 proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${config.sops.templates."sing-box-proxy.json".path}";
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

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  boot.kernelPackages = mkForce pkgs.linuxPackages_6_18;
  my.essentials.zfs = {
    enable = true;
    enableZed = true;
    enableZfsUnstable = true;
    arcMaxBytes = 12 * 1024 * 1024 * 1024;
  };
  my.essentials.gui.enable = true;

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
      IPv6AcceptRA = false;
      LinkLocalAddressing = "ipv6";
    };
    routes = [
      {
        Gateway = gateway;
        GatewayOnLink = true;
      }
    ];
  };

  my.services.proxmox = {
    enable = true;
    ipAddress = "192.168.88.29";
    bridges = [ "vmbr0" ];
    enableDashboardProxy = true;
    fakeSubscription = {
      enable = true;
      blockRemoteChecks = true;
    };
  };

  my.services.guiTestSandbox.enable = true;

  # Keep agent-driven activation scoped to this host and flake target.
  security.sudo.extraRules = [
    {
      users = [ "sinkerine" ];
      commands = [
        {
          command = "/run/current-system/sw/bin/nixos-rebuild switch --flake /nixfiles\\#kazuki";
          options = [ "NOPASSWD" ];
        }
        {
          command = "/run/current-system/sw/bin/deploy *";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    modesetting.enable = true;
    powerManagement.enable = true;
    open = true;
  };

  boot.kernelParams = [
    "acpi_enforce_resources=lax"
    "transparent_hugepage=never"
    # Trace udev events in both initrd and the real system. Useful when a
    # worker hangs while initrd udev is stopped during the stage-1 handoff.
    "rd.udev.log_level=debug"
    "udev.log_level=debug"
  ];
  hardware = {
    i2c = {
      enable = true;
    };
  };
  services.fwupd.enable = true;

  # Bound hangs while retaining debug logs needed to identify the worker and
  # device. The initrd instance stops during stage-1 handoff; the normal
  # instance stops during shutdown.
  boot.initrd.systemd.services.systemd-udevd.serviceConfig.TimeoutStopSec = 10;
  systemd.services.systemd-udevd.serviceConfig.TimeoutStopSec = 10;

  my.services.zrepl = {
    enable = true;
    ports = { inherit (config.my.ports.zrepl.kazuki) push; };
    configTemplateFile = ./zrepl/zrepl.yaml.jinja;
    sopsCertFile = ./zrepl/kazuki.m.mado.moe.crt;
    sopsKeyFile = ./zrepl/kazuki.m.mado.moe.key;
  };

  programs.virt-manager.enable = true;
  programs.steam.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;

  my.services.aria2 = {
    package = pkgs.aria2-fast;
    maxConnectionPerServer = 128;
  };
  hardware.graphics.enable32Bit = true;

  my.services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };
  my.services.gateway = {
    enable = true;
    enableDocker = true;
    internalDomain = "${hostname}.m.mado.moe";
    lanOnlyIpRanges = [
      config.my.ip.ranges.local
      config.my.ip.ranges.lan
      config.my.ip.ranges.wireguard
      config.my.ip.ranges.tailscale
    ];
  };

  # Local OpenAI-compatible inference endpoint for Hermes and other agents.
  systemd.services.llama-qwen35 = {
    description = "llama.cpp Qwen3.5 9B inference server";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig = {
      ConditionPathExists = [
        "/home/sinkerine/.cache/llama.cpp/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
        "/home/sinkerine/.cache/llama.cpp/mmproj-Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-BF16.gguf"
      ];
    };
    serviceConfig = {
      User = "sinkerine";
      Group = "users";
      ExecStart = ''
        ${lib.getExe' pkgs.llama-cpp-cuda "llama-server"} \
          --model /home/sinkerine/.cache/llama.cpp/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf \
          --alias Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M \
          --mmproj /home/sinkerine/.cache/llama.cpp/mmproj-Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-BF16.gguf \
          --host 127.0.0.1 \
          --port 8081 \
          --ctx-size 131072 \
          --parallel 1 \
          --n-gpu-layers 32 \
          --flash-attn on \
          --cache-type-k q8_0 \
          --cache-type-v q8_0 \
          --chat-template-kwargs '{"enable_thinking":false}' \
          --metrics
      '';
      Restart = "on-failure";
      RestartSec = 5;
      SupplementaryGroups = [ "video" "render" ];
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = "read-only";
      ReadWritePaths = [ "/home/sinkerine/.cache/llama.cpp" ];
    };
  };

  services.traefik.dynamicConfigOptions.http = {
    routers.llamaQwen35 = {
      rule = "Host(`llama.${hostname}.m.mado.moe`)";
      middlewares = [ "lan-only@file" ];
      service = "llamaQwen35";
    };
    services.llamaQwen35.loadBalancer.servers = [
      { url = "http://127.0.0.1:8081"; }
    ];
  };
  my.services.smartd.enable = true;
  my.services.metrics = {
    enable = true;
    enableScrapeSmartctl = true;
  };
}
