{ config, pkgs, lib, ... }:

with lib; {
  home.stateVersion = "26.05";

  home = rec {
    username = "work";
    homeDirectory = "/home/work";
  };

  imports = [
    ../../../common/baseline.nix
    # XSession related
    ../../../features/conf/xsession
    ../../../features/conf/xresources
    ../../../features/app/unclutter
    ../../../features/app/wallpaper
    # Applications
    ../../../features/app/rofi
    ../../../features/app/picom
    ../../../features/app/arandr
  ];

  home.packages = with pkgs; [
    keepassxc
    firefox-devedition-bin
    clementine
    nautilus
    kdePackages.ark
    unrar
    kdePackages.kate
    kdePackages.gwenview
    kdePackages.okular
    xclip
  ];

  home.sessionVariables = {
    PATH = "${config.home.homeDirectory}/.nix-profile/bin:$PATH";
    XDG_DATA_DIRS = "$XDG_DATA_DIRS:$HOME/.nix-profile/share";
  };

  xresources.properties."Xft.dpi" = mkForce 120;
  xresources.properties."Xcursor.size" = mkForce 32;

  my.programs.zsh.isXorg = true;
  programs.zsh.shellAliases = {
    # Nix Home Manager
    snh = "switch-nix-home.sh";
    # NixOS
    sno = "switch-nix-os.sh";
  };

  my.xsession.i3 = {
    enable = true;
    monitors = {
      one = "DisplayPort-1";
      two = "DisplayPort-3";
    };
  };
  qt.enable = true;
  gtk.enable = true;
  xdg.userDirs = {
    enable = true;
    createDirectories = true;
  };
  my.programs.fontconfig.enableGui = true;

  my.programs.nvim = { enable = true; };
  my.services.dunst.enable = true;
  my.programs.networkmanager-dmenu = {
    enable = true;
    settings = {
      dmenu.dmenu_command = "${config.programs.rofi.package}/bin/rofi -dmenu";
    };
  };

  my.programs.nixGL.enable = true;
  my.programs.nixGL.package = pkgs.nixgl.nixGLMesa;
  my.programs.hmSwitch.useImpure = true;
  my.services.playerctld.enable = true;
  my.programs.alacritty.enable = true;
  my.services.flameshot.enable = true;
  my.services.redshift.enable = true;
}
