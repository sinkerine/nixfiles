{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.foot;
in {
  options.my.programs.foot = {
    enable = mkEnableOption "Foot terminal";
    fontSize = mkOption {
      type = types.int;
      default = 14;
      description = "Font size for Foot terminal";
    };
  };
  config = mkIf cfg.enable {
    my.programs.set-theme.files."foot/theme.ini" = lib.genAttrs [ "dark" "light" ] (mode:
      pkgs.writeText "foot-theme-${mode}.ini" "[main]\ninitial-color-theme=${mode}\n");
    programs.foot = {
      enable = true;
      settings = {
        main = {
          term = "foot";
          shell = "${pkgs.tmux}/bin/tmux new-session -A -s main";
          font = "Sarasa Mono SC Nerd Font:size=${toString cfg.fontSize}";
          dpi-aware = "yes";
          include = "${config.xdg.configHome}/foot/theme.ini";
        };
        mouse = { hide-when-typing = "yes"; };
        colors-dark = {
          foreground = "c5c8c6";
          background = "1d1f21";
          regular0 = "1d1f21"; # black
          regular1 = "cc6666"; # red
          regular2 = "b5bd68"; # green
          regular3 = "e6c547"; # yellow
          regular4 = "81a2be"; # blue
          regular5 = "b294bb"; # magenta
          regular6 = "70c0ba"; # cyan
          regular7 = "373b41"; # white
          bright0 = "666666"; # bright black
          bright1 = "ff3334"; # bright red
          bright2 = "9ec400"; # bright green
          bright3 = "f0c674"; # bright yellow
          bright4 = "81a2be"; # bright blue
          bright5 = "b77ee0"; # bright magenta
          bright6 = "54ced6"; # bright cyan
          bright7 = "282a2e"; # bright white
          dim-blend-towards = "black";
        };
        colors-light = {
          foreground = "586e75";
          background = "fdf6e3";
          regular0 = "073642"; # black
          regular1 = "dc322f"; # red
          regular2 = "859900"; # green
          regular3 = "b58900"; # yellow
          regular4 = "268bd2"; # blue
          regular5 = "d33682"; # magenta
          regular6 = "2aa198"; # cyan
          regular7 = "eee8d5"; # white
          bright0 = "002b36"; # bright black
          bright1 = "cb4b16"; # bright red
          bright2 = "586e75"; # bright green
          bright3 = "657b83"; # bright yellow
          bright4 = "839496"; # bright blue
          bright5 = "6c71c4"; # bright magenta
          bright6 = "93a1a1"; # bright cyan
          bright7 = "fdf6e3"; # bright white
          dim-blend-towards = "white";
        };
        key-bindings = {
          clipboard-copy = "Control+Shift+c XF86Copy";
          clipboard-paste = "Control+Shift+v XF86Paste";
          primary-paste = "Shift+Insert";
          search-start = "Control+Shift+r";
          font-increase = "Control+plus Control+equal Control+KP_Add";
          font-decrease = "Control+minus Control+KP_Subtract";
          font-reset = "Control+0 Control+KP_0";
          spawn-terminal = "Control+Shift+n";
          minimize = "none";
          maximize = "none";
          fullscreen = "F11";
          pipe-visible = "Control+Shift+period";
          pipe-scrollback = "Control+Shift+slash";
          pipe-selected = "Control+Shift+pipe";
          show-urls-launch = "Control+Shift+u";
          show-urls-copy = "Control+Shift+o";
          show-urls-persistent = "none";
          prompt-prev = "Control+Shift+z";
          prompt-next = "Control+Shift+x";
          unicode-input = "Control+Shift+i";
          color-theme-toggle = "Control+Shift+t";
          noop = "none";
        };
      };
    };
  };
}
