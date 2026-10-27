{
  config,
  lib,
  pkgs,
  pkgsStable,
  ...
}:

{
  home.stateVersion = "26.05";

  imports = [ ../common ];

  my.programs.vm-test.enable = true;
  my.programs.paseo = {
    enable = true;
    desktop.enable = true;
    daemon.enable = true;
    daemon.hostnames = [ "paeso.kazuki.m.mado.moe" ];
    integrations.enable = true;
  };

  programs.noctalia.settings.lockscreen.enabled = lib.mkForce false;

  my.profiles.trusted.enable = true;
  my.essentials.gui.enable = true;

  home.packages = with pkgs; [
    pkgsStable.handbrake
    p7zip
    wineWow64Packages.stable
    winetricks
    (retroarch.withCores (libretro: [ libretro.mgba ]))
  ];

  my.programs.hyprland = {
    extraSessionVariables = {
      LIBVA_DRIVER_NAME = "nvidia";
      NVD_BACKEND = "direct";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      ELECTRON_OZONE_PLATFORM_HINT = "auto";
    };
  };

  home.sessionVariables = {
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    LIBVA_DRIVER_NAME = "nvidia";
    NVD_BACKEND = "direct";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
  };

  my.display.monitors = {
    one = {
      # https://wiki.hyprland.org/Configuring/Monitors/
      output = "desc:Dell Inc. DELL P2715Q 54KKD77P721L";
      wallpaper = "${config.home.homeDirectory}/Pictures/wallpapers/yande.re_455471_armor_fate_grand_order_heels_landscape_shielder_(fate_grand_order)_thighhighs_thkani@2x.png";
    };
    two = {
      output = "desc:Dell Inc. DELL U2718Q 4K8X78BC0DNL";
      wallpaper = "${config.home.homeDirectory}/Pictures/wallpapers/yande_128733_dress_kagome_keroq_minakami_yuki_smoking_subarashiki_hibi_thighhighs@2x.png";
    };
  };
  my.display.scale = 2.0;
  dconf.settings = {
    "org/virt-manager/virt-manager/connections" = {
      autoconnect = [ "qemu:///system" ];
      uris = [ "qemu:///system" ];
    };
  };
}
