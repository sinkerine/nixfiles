{ pkgs, lib, mylib, ... }:

let
  inherit (mylib) templateFile;
in {
  home.packages = [ pkgs.rofi pkgs.rofi-emoji ];

  my.programs.set-theme.files."rofi/config.rasi" = lib.genAttrs [ "dark" "light" ] (theme:
    templateFile "rofi-config-${theme}" { inherit theme; } ./config.rasi.jinja);
  xdg.configFile = {
    "rofi/nord.rasi".source = ./nord.rasi;
    "rofi/gruvbox-light-soft.rasi".source = ./gruvbox-light-soft.rasi;
    "rofi/gruvbox-common.inc.rasi".source = ./gruvbox-common.inc.rasi;
  };
}
