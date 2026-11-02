{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.herdr;
in {
  options.my.programs.herdr = {
    enable = mkEnableOption "Herdr terminal multiplexer";
    package = mkOption {
      type = types.package;
      default = pkgs.herdr;
      description = "Herdr package to install and use.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    programs.zsh.shellAliases = {
      h = "herdr";
      hs = "herdr --session";
      hl = "herdr session list";
      hks = "herdr session stop";
    };

    my.programs.set-theme.files."herdr/config.toml" = genAttrs [ "dark" "light" ] (theme:
      pkgs.writeText "herdr-${theme}.toml" ''
      # Managed by Home Manager.
      onboarding = false

      [theme]
      name = "${if theme == "light" then "tokyo-night-day" else "monokai"}"

      [terminal]
      # Empty means $SHELL, then /bin/sh.
      default_shell = ""
      shell_mode = "non_login"
      new_cwd = "follow"

      [ui]
      pane_borders = true
      pane_gaps = true
      show_agent_labels_on_pane_borders = true

      [keys]
      prefix = "f8"

      # Session/workspace controls.
      new_workspace = "prefix+shift+n"
      rename_workspace = "prefix+shift+w"
      close_workspace = "prefix+shift+d"
      workspace_picker = "prefix+g"
      detach = "prefix+q"

      # Pane navigation and movement.
      focus_pane_left = "prefix+h"
      focus_pane_down = "prefix+j"
      focus_pane_up = "prefix+k"
      focus_pane_right = "prefix+l"
      swap_pane_down = "prefix+shift+j"
      swap_pane_up = "prefix+shift+k"
      swap_pane_left = "prefix+shift+h"
      swap_pane_right = "prefix+shift+l"
      split_vertical = "prefix+v"
      split_horizontal = "prefix+minus"
      close_pane = "prefix+x"
      zoom = "prefix+z"
      resize_mode = "prefix+r"

      # Tab controls.
      new_tab = "prefix+c"
      rename_tab = "prefix+shift+t"
      previous_tab = "prefix+p"
      next_tab = "prefix+n"
      close_tab = "prefix+shift+x"
      switch_tab = "prefix+1..9"

      # Tmux-style copy mode.
      copy_mode = "prefix+["
      toggle_sidebar = "prefix+b"
      help = "prefix+?"
      settings = "prefix+s"
      reload_config = "prefix+shift+r"
    '');
  };
}
