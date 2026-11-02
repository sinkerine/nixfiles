{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.alacritty;
  colors = theme: (if theme == "light" then { # Soloriazed light
          primary = {
            background = "0xfdf6e3";
            foreground = "0x586e75";
          };
          # Colors the cursor will use if `custom_cursor_colors` is true
          cursor = {
            text = "0xfdf6e3";
            cursor = "0x586e75";
          };
          normal = {
            black = "0x073642";
            red = "0xdc322f";
            green = "0x859900";
            yellow = "0xb58900";
            blue = "0x268bd2";
            magenta = "0xd33682";
            cyan = "0x2aa198";
            white = "0xeee8d5";
          };
          bright = {
            black = "0x002b36";
            red = "0xcb4b16";
            green = "0x586e75";
            yellow = "0x657b83";
            blue = "0x839496";
            magenta = "0x6c71c4";
            cyan = "0x93a1a1";
            white = "0xfdf6e3";
          };
        } else { # Nord
          primary = {
            background = "0x1d1f21";
            foreground = "0xc5c8c6";
          };
          # Colors the cursor will use if `custom_cursor_colors` is true
          cursor = {
            text = "0x1d1f21";
            cursor = "0xffffff";
          };
          normal = {
            black = "0x1d1f21";
            red = "0xcc6666";
            green = "0xb5bd68";
            yellow = "0xe6c547";
            blue = "0x81a2be";
            magenta = "0xb294bb";
            cyan = "0x70c0ba";
            white = "0x373b41";
          };
          bright = {
            black = "0x666666";
            red = "0xff3334";
            green = "0x9ec400";
            yellow = "0xf0c674";
            blue = "0x81a2be";
            magenta = "0xb77ee0";
            cyan = "0x54ced6";
            white = "0x282a2e";
          };
        });
in {
  options.my.programs.alacritty = { enable = mkEnableOption "Alacritty"; };
  config = mkIf cfg.enable {
    my.programs.set-theme.files."alacritty/theme.toml" = genAttrs [ "dark" "light" ] (mode:
      (pkgs.formats.toml { }).generate "alacritty-theme-${mode}.toml" { colors = colors mode; });
    programs.alacritty = {
      enable = true;
      settings = {
        terminal.shell = {
          program = "${pkgs.herdr}/bin/herdr";
          args = [ ];
        };
        font = {
          normal = {
            family = "Sarasa Mono SC Nerd Font";
            style = "Medium";
          };
          bold = {
            family = "Sarasa Mono SC Nerd Font";
            style = "Bold";
          };
          italic = {
            family = "Sarasa Mono SC Nerd Font";
            style = "Italic";
          };
          # Point size of the font
          size = 13;
        };
        general.import = [ "${config.xdg.configHome}/alacritty/theme.toml" ];
        bell = {
          animation = "EaseOutExpo";
          duration = 0;
        };
        keyboard.bindings = (if pkgs.stdenv.hostPlatform.isLinux then [
          {
            key = "V";
            mods = "Control|Shift";
            action = "Paste";
          }
          {
            key = "C";
            mods = "Control|Shift";
            action = "Copy";
          }
        ] else [
          {
            key = "Q";
            mods = "Command";
            action = "Quit";
          }
          {
            key = "W";
            mods = "Command";
            action = "Quit";
          }
          # Fix alt on Mac
          {
            key = "A";
            mods = "Alt";
            chars = "x1ba";
          }
          {
            key = "B";
            mods = "Alt";
            chars = "x1bb";
          }
          {
            key = "C";
            mods = "Alt";
            chars = "x1bc";
          }
          {
            key = "D";
            mods = "Alt";
            chars = "x1bd";
          }
          {
            key = "E";
            mods = "Alt";
            chars = "x1be";
          }
          {
            key = "F";
            mods = "Alt";
            chars = "x1bf";
          }
          {
            key = "G";
            mods = "Alt";
            chars = "x1bg";
          }
          {
            key = "H";
            mods = "Alt";
            chars = "x1bh";
          }
          {
            key = "I";
            mods = "Alt";
            chars = "x1bi";
          }
          {
            key = "J";
            mods = "Alt";
            chars = "x1bj";
          }
          {
            key = "K";
            mods = "Alt";
            chars = "x1bk";
          }
          {
            key = "L";
            mods = "Alt";
            chars = "x1bl";
          }
          {
            key = "M";
            mods = "Alt";
            chars = "x1bm";
          }
          {
            key = "N";
            mods = "Alt";
            chars = "x1bn";
          }
          {
            key = "O";
            mods = "Alt";
            chars = "x1bo";
          }
          {
            key = "P";
            mods = "Alt";
            chars = "x1bp";
          }
          {
            key = "Q";
            mods = "Alt";
            chars = "x1bq";
          }
          {
            key = "R";
            mods = "Alt";
            chars = "x1br";
          }
          {
            key = "S";
            mods = "Alt";
            chars = "x1bs";
          }
          {
            key = "T";
            mods = "Alt";
            chars = "x1bt";
          }
          {
            key = "U";
            mods = "Alt";
            chars = "x1bu";
          }
          {
            key = "V";
            mods = "Alt";
            chars = "x1bv";
          }
          {
            key = "W";
            mods = "Alt";
            chars = "x1bw";
          }
          {
            key = "X";
            mods = "Alt";
            chars = "x1bx";
          }
          {
            key = "Y";
            mods = "Alt";
            chars = "x1by";
          }
          {
            key = "Z";
            mods = "Alt";
            chars = "x1bz";
          }
          {
            key = "A";
            mods = "Alt|Shift";
            chars = "x1bA";
          }
          {
            key = "B";
            mods = "Alt|Shift";
            chars = "x1bB";
          }
          {
            key = "C";
            mods = "Alt|Shift";
            chars = "x1bC";
          }
          {
            key = "D";
            mods = "Alt|Shift";
            chars = "x1bD";
          }
          {
            key = "E";
            mods = "Alt|Shift";
            chars = "x1bE";
          }
          {
            key = "F";
            mods = "Alt|Shift";
            chars = "x1bF";
          }
          {
            key = "G";
            mods = "Alt|Shift";
            chars = "x1bG";
          }
          {
            key = "H";
            mods = "Alt|Shift";
            chars = "x1bH";
          }
          {
            key = "I";
            mods = "Alt|Shift";
            chars = "x1bI";
          }
          {
            key = "J";
            mods = "Alt|Shift";
            chars = "x1bJ";
          }
          {
            key = "K";
            mods = "Alt|Shift";
            chars = "x1bK";
          }
          {
            key = "L";
            mods = "Alt|Shift";
            chars = "x1bL";
          }
          {
            key = "M";
            mods = "Alt|Shift";
            chars = "x1bM";
          }
          {
            key = "N";
            mods = "Alt|Shift";
            chars = "x1bN";
          }
          {
            key = "O";
            mods = "Alt|Shift";
            chars = "x1bO";
          }
          {
            key = "P";
            mods = "Alt|Shift";
            chars = "x1bP";
          }
          {
            key = "Q";
            mods = "Alt|Shift";
            chars = "x1bQ";
          }
          {
            key = "R";
            mods = "Alt|Shift";
            chars = "x1bR";
          }
          {
            key = "S";
            mods = "Alt|Shift";
            chars = "x1bS";
          }
          {
            key = "T";
            mods = "Alt|Shift";
            chars = "x1bT";
          }
          {
            key = "U";
            mods = "Alt|Shift";
            chars = "x1bU";
          }
          {
            key = "V";
            mods = "Alt|Shift";
            chars = "x1bV";
          }
          {
            key = "W";
            mods = "Alt|Shift";
            chars = "x1bW";
          }
          {
            key = "X";
            mods = "Alt|Shift";
            chars = "x1bX";
          }
          {
            key = "Y";
            mods = "Alt|Shift";
            chars = "x1bY";
          }
          {
            key = "Z";
            mods = "Alt|Shift";
            chars = "x1bZ";
          }
          {
            key = "Key1";
            mods = "Alt";
            chars = "x1b1";
          }
          {
            key = "Key2";
            mods = "Alt";
            chars = "x1b2";
          }
          {
            key = "Key3";
            mods = "Alt";
            chars = "x1b3";
          }
          {
            key = "Key4";
            mods = "Alt";
            chars = "x1b4";
          }
          {
            key = "Key5";
            mods = "Alt";
            chars = "x1b5";
          }
          {
            key = "Key6";
            mods = "Alt";
            chars = "x1b6";
          }
          {
            key = "Key7";
            mods = "Alt";
            chars = "x1b7";
          }
          {
            key = "Key8";
            mods = "Alt";
            chars = "x1b8";
          }
          {
            key = "Key9";
            mods = "Alt";
            chars = "x1b9";
          }
          {
            key = "Key0";
            mods = "Alt";
            chars = "x1b0";
          }
          {
            key = "Grave";
            mods = "Alt";
            chars = "x1b`";
          } # Alt + `
          {
            key = "Grave";
            mods = "Alt|Shift";
            chars = "x1b~";
          } # Alt + ~
          {
            key = "Period";
            mods = "Alt";
            chars = "x1b.";
          } # Alt + .
          {
            key = "Key8";
            mods = "Alt|Shift";
            chars = "x1b*";
          } # Alt + *
          {
            key = "Key3";
            mods = "Alt|Shift";
            chars = "x1b#";
          } # Alt + #
        ]);
      };
    };
  };
}
