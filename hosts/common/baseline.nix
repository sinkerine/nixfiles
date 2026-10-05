{
  config,
  pkgs,
  lib,
  hostname,
  ...
}:

with lib;
{
  services.dbus.implementation = "broker";

  environment.systemPackages = with pkgs; [
    sops
    acpi
    wget
    rename
    zip
    killall
    pciutils
    usbutils
    openssl
    sops
    gnupg
    age
    ncdu
    inetutils
    python3
    headscale
    tailscale
    smartmontools
    nix-index
    iperf
    jq
    lm_sensors
    git
  ];

  nix = {
    gc = {
      automatic = true;
      options = "--delete-older-than 7d";
      dates = "weekly";
    };
    settings = {
      accept-flake-config = true;
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      substituters = [
        "https://nix-community.cachix.org"
        "https://cache.nixos.org/"
        "https://cache.numtide.com"
        "https://hyprland.cachix.org"
        "https://cache.nixos-cuda.org"
        "https://cache.saumon.network/proxmox-nixos"
      ];
      trusted-public-keys = config.my.trusts.cache.pubKeys;
      # Allows deploy-rs to add nix closure as non-root users in the wheel group. It resolves the error in home-manager: "cannot add path xxx because it lacks a signature by a trusted key"
      trusted-users = [
        "root"
        "@wheel"
      ];
      download-buffer-size = 209715200; # 200 MiB
    };
  };

  networking.hostName = lib.mkDefault hostname;
  # For zfs to identify machines.
  networking.hostId = builtins.getAttr hostname config.my.ids.hostIds;

  users.mutableUsers = false;
  hardware.enableRedistributableFirmware = true;
  time.timeZone = "America/Los_Angeles";
  services.acpid.enable = true;
  programs.zsh.enable = true;

  security.pam.loginLimits = [
    {
      domain = "@wheel";
      type = "-";
      item = "nice";
      value = "-19";
    }
    {
      domain = "@wheel";
      type = "-";
      item = "rtprio";
      value = "95";
    }
    {
      domain = "@wheel";
      type = "-";
      item = "memlock";
      value = "4194304";
    }
    {
      domain = "*";
      type = "soft";
      item = "nofile";
      value = "10240";
    }
  ];
  security.pam.services.hyprlock = {
    text = ''
      auth include login
    '';
  };

  security.polkit = {
    enable = true;
    extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (
          subject.isInGroup("wheel")
            && (
              action.id == "org.freedesktop.login1.reboot" ||
              action.id == "org.freedesktop.login1.reboot-multiple-sessions" ||
              action.id == "org.freedesktop.login1.power-off" ||
              action.id == "org.freedesktop.login1.power-off-multiple-sessions"
            )
          )
        {
          return polkit.Result.YES;
        }
      })
    '';
  };

  system.activationScripts.linkTzdata = ''
    if ! [ -L /usr/share/zoneinfo ]; then
      mkdir -p /usr/share
      ln -sf ${pkgs.tzdata}/share/zoneinfo /usr/share/zoneinfo
    fi
  '';

  boot.kernel.sysctl = {
    "vm.max_map_count" = 524288;
    "vm.overcommit_memory" = 1;
    "fs.inotify.max_user_watches" = 200000;
    "fs.inotify.max_user_instances" = 8192;
  };
  networking.firewall = {
    enable = true;
    # https://docs.syncthing.net/users/firewall.html
    allowedTCPPorts = [ 22000 ];
    allowedUDPPorts = [
      22000
      21027
    ];
  };
  sops.secrets.smtpPassword = {
    sopsFile = ./secrets.yaml;
    mode = "0440";
    group = "smtp-secret";
  };
  environment.etc."aliases".text = ''
    root: ${hostname}-sysadmin@15cm.net
  '';
  programs.msmtp = {
    enable = true;
    setSendmail = true;
    defaults = {
      aliases = "/etc/aliases";
      port = 465;
      tls_trust_file = "/etc/ssl/certs/ca-certificates.crt";
      tls = "on";
      auth = "login";
      tls_starttls = "off";
    };
    accounts = {
      default = {
        host = "smtp.gmail.com";
        passwordeval = "cat ${config.sops.secrets.smtpPassword.path}";
        user = "admin@15cm.net";
        from = "noreply.sysadmin@15cm.net";
      };
    };
  };

  # https://github.com/NixOS/nixpkgs/issues/180175
  systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;
  systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
}
