{ config, lib, pkgs, mylib, ... }:

with lib;
let
  cfg = config.my.programs.powerline;
  inherit (mylib) templateFile;
in {
  options.my.programs.powerline = {
    enable = mkEnableOption "Powerline";
    package = mkOption {
      type = types.package;
      default = pkgs.powerline;
    };
  };
  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];
    my.programs.set-theme.files."powerline/config.json" = genAttrs [ "dark" "light" ] (mode:
      templateFile "powerline-config-${mode}" {
        colorScheme = if mode == "light" then "solarized-light" else "nord";
      } ./config.json.jinja);
    xdg.configFile = {
      "powerline/color.json".source = ./colors.json;
      "powerline/colorschemes".source = ./colorschemes;
      "powerline/themes".source = ./themes;
    };
    programs.zsh.initContent = mkAfter ''
      # Powerline
      export POWERLINE_CONFIG_COMMAND=${cfg.package}/bin/powerline-config
      powerline-daemon -q
      source ${cfg.package}/share/zsh/powerline.zsh
    '';
    programs.tmux.extraConfig = ''
      # Powerline
      source ${cfg.package}/share/tmux/powerline.conf
    '';
  };
}
