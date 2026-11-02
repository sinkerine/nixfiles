{ config, mylib, hostname, pkgs, lib, ... }:

with lib;
let
  cfg = config.my.xsession.i3;
  inherit (mylib) templateFile templateShellScriptFile writeShellScriptFile;
  templateData = theme: {
    inherit hostname;
    inherit theme;
    inherit (cfg) musicPlayer;
    colorScheme = (if theme == "light" then "solarized-light" else "nord-dark");
    monitors = cfg.monitors;
    i3statusRustBinary = "${pkgs.i3status-rust}/bin/i3status-rs";
  };
in {
  options.my.xsession.i3 = {
    enable = mkEnableOption "i3";
    musicPlayer = mkOption {
      type = types.str;
      default = "Feishin";
    };
    monitors = mkOption {
      type = with types; attrsOf str;
      default = {
        one = "DP-0";
        two = "DP-2";
      };
    };
  };

  config = mkIf cfg.enable {
    xsession.windowManager.i3 = {
      enable = true;
      config = null;

    };

    # i3 Scripts
    xdg.configFile."i3/scripts/i3exit.sh".source =
      writeShellScriptFile "i3-scripts-i3exit.sh" ./scripts/i3exit.sh;

    # Other i3 related packages.
    home.packages = [ pkgs.i3status-rust pkgs.i3-quickterm ];
    my.programs.set-theme.files = {
      "i3/config" = genAttrs [ "dark" "light" ] (mode:
        templateFile "i3-config-${mode}" (templateData mode) ./config.jinja);
      "i3status-rust/config.toml" = genAttrs [ "dark" "light" ] (mode:
        templateFile "i3status-rust-${mode}" (templateData mode) ./status.toml.jinja);
    };
    xdg.configFile."i3/i3-quickterm.json".source = ./i3-quickterm.json;
  };
}
