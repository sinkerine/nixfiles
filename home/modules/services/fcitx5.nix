{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.my.services.fcitx5;
in
{
  imports = [ ./rime-wanxiang.nix ];

  options.my.services.fcitx5 = {
    enable = mkEnableOption "Fcitx5";

    addons = mkOption {
      type = types.listOf types.package;
      default = [ ];
    };

    package = mkOption {
      type = types.package;
      default = pkgs.qt6Packages.fcitx5-with-addons.override {
        inherit (cfg) addons;
      };
    };

    enableWaylandEnv = mkEnableOption "https://fcitx-im.org/wiki/Using_Fcitx_5_on_Wayland";
  };

  config = mkIf cfg.enable {
    my.services.fcitx5.addons = with pkgs; [
      fcitx5-rime
      fcitx5-mozc
    ];

    home.packages = with pkgs; [
      fcitx5-gtk
      kdePackages.fcitx5-qt
    ];

    home.sessionVariables = {
      QT_IM_MODULES = "wayland;fcitx";
      QT_IM_MODULE = "fcitx";
      XMODIFIERS = "@im=fcitx";
      QT_PLUGIN_PATH = "${cfg.package}/${pkgs.qt6.qtbase.qtPluginPrefix}:\${QT_PLUGIN_PATH}";
    };

    gtk = {
      gtk2.extraConfig = ''gtk-im-module="fcitx"'';
      gtk3.extraConfig = {
        gtk-im-module = "fcitx";
      };
      gtk4.extraConfig = {
        gtk-im-module = "fcitx";
      };
    };

    home.file.".local/share/fcitx5/themes/Material-Color-Pink/theme.conf".source = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/hosxy/Fcitx5-Material-Color/2256feeae48dcc87f19a3cfe98f171862f8fcace/theme-pink.conf";
      hash = "sha256-VbYvwAb3pxyReFzl7j3eqqUsMuSY32+XlEhBNb12ZRc=";
    };

    systemd.user.services.fcitx5-daemon = {
      Unit = {
        Description = "Fcitx5 input method editor";
        PartOf = mkForce [ "tray.target" ];
        After = mkForce [ "tray.target" ];
      };
      Service.ExecStart = "${cfg.package}/bin/fcitx5";
      Install.WantedBy = mkForce [ "tray.target" ];
    };
  };
}
