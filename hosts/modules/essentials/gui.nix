{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.my.essentials.gui;
in
{
  options.my.essentials.gui = {
    enable = mkEnableOption "linux gui";
  };

  config = mkIf cfg.enable (mkMerge [
    {
      programs.hyprland = {
        enable = true;
        withUWSM = true;
        xwayland = {
          enable = true;
        };
      };
      programs.niri = {
        enable = true;
        package = pkgs.niri;
      };
      programs.uwsm.waylandCompositors.niri = {
        prettyName = "Niri";
        comment = "Niri compositor managed by UWSM";
        binPath = "/run/current-system/sw/bin/niri";
        extraArgs = [ "--session" ];
      };
      services.displayManager.defaultSession = "niri-uwsm";
    }
    {
      environment.systemPackages = with pkgs; [
        exfat
        exfatprogs
        pavucontrol
        pulseaudio
        xev
        evtest
        mpv
        deploy-rs
        mesa-demos
        ventoy
      ];

      # Make GRUB wait indefinitely for user input.
      boot.loader.timeout = -1;

      fonts.packages = with pkgs; [ noto-fonts ];
      # GUI apps expect a system default fonts.conf. Home Manager fontconfig only
      # adds user-level snippets and profile font paths.
      fonts.fontconfig.enable = true;

      # For easy effects https://github.com/nix-community/home-manager/issues/3113
      # Required by pipewire rt mod and Flatpak.
      programs.dconf.enable = true;
      # Provide the AT-SPI accessibility bus used by CUA for UI inspection.
      services.gnome.at-spi2-core.enable = true;
      # SSH authentication is provided by the Home Manager OpenSSH agent.
      services.gnome.gcr-ssh-agent.enable = lib.mkForce false;
      programs.nix-ld.enable = true;
      security.rtkit.enable = true;
      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };

      xdg.portal = {
        enable = true;
        extraPortals = with pkgs; [ xdg-desktop-portal-gtk ];
        config.common.default = "*";
      };

      hardware.bluetooth.enable = true;
      services.blueman.enable = true;
      services.geoclue2.enable = true;

      services.flatpak.enable = true;
      # Needed by Nautilus/Nemo.
      services.gvfs.enable = true;

      programs.wireshark = {
        enable = true;
        package = pkgs.wireshark;
      };

      my.services.docker.enable = true;
      my.services.autofs.enable = true;
      my.services.aria2 = {
        enable = true;
        downloadDir = "/home/sinkerine/Downloads";
        enableSession = true;
        enableReverseProxy = true;
      };
      services.printing = {
        enable = true;
        drivers = with pkgs; [ hplip ];
      };
      services.avahi.enable = true;
      services.avahi.nssmdns4 = true;

      system.activationScripts.linkBinaries = ''
        ln -sf ${pkgs.mpv}/bin/mpv /usr/bin/mpv
      '';

      # systemd.services.restart-network-manager-on-resume = {
      #   enable = true;
      #   description = "Restart network manager on system resume";
      #   serviceConfig = {
      #     ExecStartPre = "${pkgs.coreutils}/bin/sleep 3";
      #     ExecStart =
      #       "${pkgs.systemd}/bin/systemctl restart NetworkManager.service";
      #     Type = "oneshot";
      #   };
      #   after = [ "systemd-suspend.service" "systemd-hibernate.service" ];
      #   requiredBy = [ "systemd-suspend.service" "systemd-hibernate.service" ];
      # };
      hardware.keyboard.qmk.enable = true;
    }
  ]);
}
