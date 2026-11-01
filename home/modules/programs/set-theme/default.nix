{ pkgs, config, lib, nixinfo, mylib, state, ... }:

with lib;
let
  cfg = config.my.programs.set-theme;
  inherit (mylib) mkDefaultTrueEnableOption;
in {
  options.my.programs.set-theme = {
    enable = mkDefaultTrueEnableOption "set-theme";
    reloadScript = mkOption {
      type = types.lines;
      default = "";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      home.file."local/bin/set-theme.sh".source =
        pkgs.writeShellScript "set-theme.sh" ''
          sed -i "s/\(theme.*\)\"[^\"]*\"/\1\"$1\"/" ${nixinfo.projectRoot}/home/state/default.nix
          switch-nix-home.sh --option substitute false
          $HOME/local/bin/reload-theme.sh
        '';

      home.file."local/bin/reload-theme.sh".source =
        pkgs.writeShellScript "reload-theme.sh"
        (config.my.programs.set-theme.reloadScript + "\n exit 0");

      programs.zsh.shellAliases = {
        stl = "set-theme.sh light";
        std = "set-theme.sh dark";
      };
    }
    {
      my.programs.set-theme.reloadScript = ''
        ${config.my.programs.powerline.package}/bin/powerline-daemon --replace
        ${config.my.programs.powerline.package}/bin/powerline-config tmux setup
      '';
    }
    (mkIf config.my.programs.emacs.enable {
      my.programs.set-theme.reloadScript = ''
        ${config.my.programs.emacs.package}/bin/emacsclient -eun '(load "~/.config/emacs-scripts/load-theme.el")'
      '';
    })
    (mkIf config.my.programs.nvim.enable {
      my.programs.set-theme.reloadScript = ''
        for addr in "$XDG_RUNTIME_DIR"/nvim.*; do
          [ -S "$addr" ] || continue
          ${pkgs.neovim}/bin/nvim --server "$addr" --remote-send ':set background=${state.theme} | :colorscheme ${config.my.programs.nvim.colorscheme}<CR>'
        done
      '';
    })
  ]);
}
