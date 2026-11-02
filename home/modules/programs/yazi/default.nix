{
  config,
  lib,
  pkgs,
  mylib,
  ...
}:

with lib;
let
  cfg = config.my.programs.yazi;
  inherit (mylib) templateFile;
  zshIntegration = ''
    function yazi_zsh() {
      local tmp="$(mktemp -t "yazi-cwd.XXXXX")"
      yazi "$@" --cwd-file="$tmp"
      if cwd="$(cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
        cd -- "$cwd"
      fi
      rm -f -- "$tmp"
    }
  '';
in
{
  options.my.programs.yazi = {
    enable = mkEnableOption "Yazi";
    package = mkOption {
      type = types.package;
      default = pkgs.yazi;
    };
  };
  config = mkIf cfg.enable {
    programs.zsh.initContent = mkOrder 600 zshIntegration;
    programs.yazi = {
      enable = true;
      inherit (cfg) package;
      shellWrapperName = "yy";
    };
    my.programs.set-theme.files."yazi/theme.toml" = genAttrs [ "dark" "light" ] (mode:
      let
        templateData =
          if mode == "light" then
            {
              theme = ./themes/catppuccin-latte.toml.jinja;
              syntectTheme = ./themes/catppuccin-latte.tmTheme;
            }
          else
            {
              theme = ./themes/catppuccin-mocha.toml.jinja;
              syntectTheme = ./themes/catppuccin-mocha.tmTheme;
            };
      in
      templateFile "yazi-theme-${mode}.toml" templateData templateData.theme);

    xdg.configFile."yazi/keymap.toml".source = ./keymap.toml;
    xdg.configFile."yazi/init.lua".source = ./init.lua;
  };
}
