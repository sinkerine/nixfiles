{
  config,
  lib,
  mylib,
  inputs,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.my.services.proxmox;
  inherit (mylib) assertNotNull;
  pvePerl = lib.head (
    lib.splitString " " (
      lib.removePrefix "#!"
        (lib.head (lib.splitString "\n" (builtins.readFile "${pkgs.pve-ha-manager}/bin/.pct-wrapped")))
    )
  );
  pvePerlEnv = builtins.dirOf (builtins.dirOf pvePerl);
  pveHookCompat = hook:
    pkgs.writeShellApplication {
      name = "${hook}-compat";
      text = ''
        exec ${pvePerl} \
          -I${pvePerlEnv}/lib/perl5/site_perl \
          -I${pvePerlEnv}/lib/perl5/site_perl/5.40.0 \
          -I${pkgs.pve-ha-manager}/lib/perl5/site_perl \
          -I${pkgs.pve-ha-manager}/lib/perl5/site_perl/5.40.0 \
          -I${pkgs.pve-rados2}/lib/perl5/site_perl \
          -I${pkgs.pve-rados2}/lib/perl5/site_perl/5.40.0 \
          -e 'my ($path) = ($ENV{PATH} =~ /^(.*)$/); $ENV{PATH} = $path; require PVE::Tools; my $read = \&PVE::Tools::file_get_contents; no warnings "redefine"; *PVE::Tools::file_get_contents = sub { my ($path, @rest) = @_; $path = "${pkgs.lxc}/share/lxc/config/common.seccomp" if $path eq "${pkgs.pve-container}/share/lxc/config/common.seccomp"; return $read->($path, @rest); }; my $script = shift @ARGV; ($script) = ($script =~ /^(.*)$/); do $script; die $@ if $@;' \
          ${pkgs.pve-container}/share/lxc/hooks/${hook} "$@"
      '';
    };
  pvePrestartHookCompat = pveHookCompat "lxc-pve-prestart-hook";
  pveAutodevHookCompat = pveHookCompat "lxc-pve-autodev-hook";
  pvePoststopHookCompat = pveHookCompat "lxc-pve-poststop-hook";
  pveLxcCommonConfig = pkgs.writeText "pve-lxc-common.conf" ''
    lxc.include = ${pkgs.lxc}/share/lxc/config/common.conf
    lxc.hook.pre-start = ${pvePrestartHookCompat}/bin/lxc-pve-prestart-hook-compat
    lxc.hook.autodev = ${pveAutodevHookCompat}/bin/lxc-pve-autodev-hook-compat
    lxc.hook.post-stop = ${pvePoststopHookCompat}/bin/lxc-pve-poststop-hook-compat
  '';
  pveLxcUsernsConfig = pkgs.writeText "pve-lxc-userns.conf" ''
    lxc.include = ${pkgs.lxc}/share/lxc/config/userns.conf
    lxc.include = ${pkgs.pve-container}/share/lxc/config/userns.conf.d/
  '';
  lxcConfigPathCompat = pkgs.writeShellApplication {
    name = "proxmox-lxc-config-path-compat";
    runtimeInputs = [ pkgs.coreutils pkgs.diffutils pkgs.gnused ];
    text = ''
      set -euo pipefail

      vmid=''${1:?missing VMID}
      config="/var/lib/lxc/$vmid/config"
      [[ -f $config ]] || exit 0
      sandbox_rootfs=0
      if [[ -r /etc/pve/lxc/$vmid.conf ]] && grep -Fq 'lxc.rootfs.mount = /run/gui-test-sandbox/rootfs/' "/etc/pve/lxc/$vmid.conf"; then
        sandbox_rootfs=1
      fi

      tmp=$(mktemp "$config.XXXXXX")
      trap 'rm -f -- "$tmp"' EXIT
      sed -E \
        -e 's#^(lxc\.include = )[^[:space:]]+/share/lxc/config/common\.conf$#\1${pveLxcCommonConfig}#' \
        -e 's#^(lxc\.include = )[^[:space:]]+/share/lxc/config/userns\.conf$#\1${pveLxcUsernsConfig}#' \
        -e 's#^(lxc\.include = )[^[:space:]]+/share/lxc/config/(nesting\.conf|oci\.common\.conf)$#\1${pkgs.lxc}/share/lxc/config/\2#' \
        "$config" > "$tmp"
      if ((sandbox_rootfs)); then
        sed -i -E '/^lxc\.rootfs\.options[[:space:]]*=/d' "$tmp"
        printf 'lxc.rootfs.options = rw\n' >> "$tmp"
      fi
      if cmp -s "$config" "$tmp"; then
        exit 0
      fi
      chmod --reference="$config" "$tmp"
      chown --reference="$config" "$tmp"
      mv -f -- "$tmp" "$config"
      trap - EXIT
    '';
  };
  pveFakeSubscriptionSrc = pkgs.fetchFromGitHub {
    owner = "Jamesits";
    repo = "pve-fake-subscription";
    rev = "v0.0.11";
    hash = "sha256-HP+4Njk0nmEcjfZlNhLQD91+3B54Y3Yc85yWVukpZZI=";
  };
  pveFakeSubscriptionPkg = pkgs.writeShellApplication {
    name = "pve-fake-subscription";
    runtimeInputs = [ pkgs.python3 ];
    text = ''
      exec python3 ${pveFakeSubscriptionSrc}/usr/bin/pve-fake-subscription "$@"
    '';
  };
in
{
  # Always import to register services.proxmox-ve options.
  imports = [ inputs.proxmox-nixos.nixosModules.proxmox-ve ];

  options.my.services.proxmox = {
    enable = mkEnableOption "Proxmox VE";

    ipAddress = mkOption {
      type = types.str;
      description = "Host IP added to /etc/hosts as <ip> <hostname>, used by Proxmox internal services for node resolution.";
      example = "192.168.1.10";
    };

    bridges = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Linux or OVS bridges visible in the Proxmox web interface.";
    };

    networking = mkOption {
      type = types.attrs;
      default = { };
      description = "Additional `networking` configuration applied when Proxmox is enabled.";
      example = {
        bridges.vmbr0.interfaces = [ "enp1s0" ];
        interfaces = {
          enp1s0.useDHCP = false;
          vmbr0.useDHCP = true;
        };
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Open firewall ports for Proxmox web UI (8006), rpcbind (111), and HTTP/HTTPS.";
    };

    enableDashboardProxy = mkEnableOption "Proxmox dashboard reverse proxy via gateway";

    fakeSubscription = {
      enable = mkEnableOption "declaratively refresh a fake Proxmox subscription cache to suppress the no-subscription prompt";

      package = mkOption {
        type = types.package;
        default = pveFakeSubscriptionPkg;
        defaultText = literalExpression "pveFakeSubscriptionPkg";
        description = "Package providing the `pve-fake-subscription` executable.";
      };

      blockRemoteChecks = mkOption {
        type = types.bool;
        default = false;
        description = "Add `shop.maurer-it.com` to `/etc/hosts` as localhost to block remote key checks.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      # Proxmox packages come from the proxmox-nixos overlay.
      nixpkgs.overlays = [
        inputs.proxmox-nixos.overlays.x86_64-linux
        (_final: prev: {
          # Upstream fetches mutable Meson subprojects in postFetch, so its
          # fixed-output hash can change without a pve-qemu revision change.
          pve-qemu = prev.pve-qemu.overrideAttrs (old: {
            src = old.src.overrideAttrs (_: {
              outputHash = "sha256-aCXlDuKYp8PZ4hVmRfyzqUwEWcDDHowI88eY/5a4pRY=";
            });
          });
        })
      ];

      services.proxmox-ve = {
        enable = true;
        inherit (cfg) ipAddress bridges openFirewall;
      };

      # PVE's Perl environment uses glibc from its pinned nixpkgs 26.05.
      # Keep PAM modules on the same glibc ABI; host nixpkgs can advance ahead
      # and otherwise PAM fails to load inside pvedaemon.
      security.pam.package = inputs.proxmox-nixpkgs.legacyPackages.${pkgs.system}.linux-pam;

      # LXC invokes Proxmox hooks directly; provide their FHS paths.
      system.activationScripts.proxmoxPerlInterpreter = ''
        install -d -m 0755 /usr/bin
        install -d -m 0755 /sbin
        ln -sfn ${pvePerl} /usr/bin/perl
        ln -sfn ${pkgs.iproute2}/bin/ip /sbin/ip
      '';

      # The unprivileged PVE LXC network helper reads this allowlist.
      environment.etc."lxc/lxc-usernet".text = concatMapStrings (bridge: "root veth ${bridge} 10\n") cfg.bridges;

      # pct invokes lxc-usernsexec by name while extracting and starting CTs.
      environment.systemPackages = [ pkgs.lxc ];

      security.wrappers.lxc-user-nic = {
        source = "${pkgs.lxc}/libexec/lxc/lxc-user-nic";
        owner = "root";
        group = "root";
        setuid = true;
      };

      systemd.services."pve-container@" = {
        description = "PVE LXC Container: %i";
        after = [ "lxc.service" ];
        wants = [ "lxc.service" ];
        path = [
          pkgs.iproute2
          pkgs.binutils
          pkgs.lxc
          pkgs.pve-container
          pkgs.util-linux
          pkgs.zfs
        ];

        unitConfig = {
          DefaultDependencies = false;
          Documentation = "man:lxc-start man:lxc man:pct";
        };

        serviceConfig = {
          Type = "simple";
          Delegate = true;
          KillMode = "mixed";
          TimeoutStopSec = 120;
          ExecStartPre = "${lib.getExe lxcConfigPathCompat} %i";
          ExecStart = "${pkgs.lxc}/bin/lxc-start -F -l DEBUG -o /run/pve/lxc-%i.log -n %i";
          ExecStop = "${pkgs.pve-container}/share/lxc/pve-container-stop-wrapper %i";
          ExecStopPost = "${pkgs.coreutils}/bin/chmod 0644 /run/pve/lxc-%i.log";
          StandardOutput = "journal";
          StandardError = "file:/run/pve/ct-%i.stderr";
        };
      };

      virtualisation.libvirtd = {
        enable = true;
        qemu.vhostUserPackages = [ pkgs.virtiofsd ];
      };

      networking = cfg.networking;

      # proxmox-nixos sets AcceptEnv as a string; NixOS expects list of string.
      services.openssh.settings.AcceptEnv = lib.mkForce [
        "LANG"
        "LC_*"
      ];
    }
    (mkIf cfg.fakeSubscription.enable {
      environment.systemPackages = [ cfg.fakeSubscription.package ];

      networking.extraHosts = mkIf cfg.fakeSubscription.blockRemoteChecks ''
        127.0.0.1 shop.maurer-it.com
      '';

      # Upstream runs the script immediately on install. Mirror that on
      # `nixos-rebuild switch` so the prompt does not linger until the timer fires.
      system.activationScripts.pveFakeSubscription.text = ''
        ${lib.getExe cfg.fakeSubscription.package}
      '';

      systemd.services.pve-fake-subscription = {
        description = "Refresh fake Proxmox subscription cache";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe cfg.fakeSubscription.package;
        };
      };

      systemd.timers.pve-fake-subscription = {
        description = "Refresh fake Proxmox subscription cache every day";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnActiveSec = "0s";
          OnBootSec = "0s";
          OnCalendar = "daily";
          RandomizedDelaySec = "60s";
          Persistent = true;
        };
      };
    })
    (mkIf cfg.enableDashboardProxy {
      services.traefik.staticConfigOptions = {
        accessLog = { };
        log.level = mkForce "DEBUG";
      };

      # Proxmox uploads large ISOs via the web UI. Traefik's default
      # entrypoint read timeout can abort slow uploads before the body finishes.
      services.traefik.staticConfigOptions.entryPoints.websecure.transport.respondingTimeouts.readTimeout =
        0;
      services.traefik.dynamicConfigOptions.http = {
        routers.proxmox = {
          rule = "Host(`vm.${assertNotNull config.my.services.gateway.internalDomain}`)";
          middlewares = [ "lan-only@file" ];
          service = "proxmox";
        };
        services.proxmox.loadBalancer = {
          servers = [ { url = "https://127.0.0.1:8006"; } ];
          passHostHeader = true;
          serversTransport = "proxmox";
        };
        serversTransports.proxmox = {
          insecureSkipVerify = true;
          disableHTTP2 = true;
        };
      };
    })
  ]);
}
