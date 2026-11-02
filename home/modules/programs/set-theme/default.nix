{ pkgs, config, lib, mylib, ... }:

let
  cfg = config.my.programs.set-theme;
  themeRoot = "${config.xdg.stateHome}/noctalia-theme";
  variants = lib.genAttrs [ "dark" "light" ] (mode:
    pkgs.linkFarm "noctalia-theme-${mode}" (lib.mapAttrsToList (name: files: {
      inherit name;
      path = files.${mode};
    }) cfg.files));
  syncTheme = pkgs.writeShellScript "sync-theme" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.procps pkgs.tmux ]}:$PATH
    mkdir -p ${lib.escapeShellArg themeRoot}
    exec 9>"${themeRoot}/sync.lock"
    ${pkgs.util-linux}/bin/flock 9
    mode="''${NOCTALIA_THEME_MODE:-$(noctalia msg theme-mode-get 2>/dev/null || true)}"
    if [ -z "$mode" ] && [ -r "${config.xdg.stateHome}/theme-mode" ]; then
      read -r mode < "${config.xdg.stateHome}/theme-mode"
    fi
    case "$mode" in
      light) source=${variants.light}; signal=USR2 ;;
      dark|"") mode=dark; source=${variants.dark}; signal=USR1 ;;
      *) echo "Unexpected Noctalia theme mode: $mode" >&2; exit 1 ;;
    esac
    mkdir -p ${lib.escapeShellArg themeRoot}
    ln -sfn "$source" "${themeRoot}/current.next"
    mv -Tf "${themeRoot}/current.next" "${themeRoot}/current"
    printf '%s\n' "$mode" > "${config.xdg.stateHome}/theme-mode"
    pkill -u "$(id -u)" -x -"$signal" foot || true
    # Daemons must not inherit the lock and block subsequent theme changes.
    (
      exec 9>&-
      ${cfg.reloadScript}
    )
  '';
in {
  options.my.programs.set-theme = {
    enable = mylib.mkDefaultTrueEnableOption "Noctalia theme synchronization";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = pkgs.runCommand "noctalia-theme-sync" { } ''
        mkdir -p $out/bin
        ln -s ${syncTheme} $out/bin/reload-theme
      '';
      description = "Standalone theme configuration and runtime reload command.";
    };
    files = lib.mkOption {
      type = with lib.types; attrsOf (attrsOf path);
      default = { };
      description = "XDG config files with light and dark variants selected by Noctalia.";
    };
    reloadScript = lib.mkOption {
      type = lib.types.lines;
      default = "";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      xdg.configFile = lib.mapAttrs (name: _: {
        source = config.lib.file.mkOutOfStoreSymlink "${themeRoot}/current/${name}";
      }) cfg.files;
      home.file."local/bin/reload-theme.sh".source = pkgs.writeShellScript "reload-theme.sh" ''
        if [ -x "${themeRoot}/package/bin/reload-theme" ]; then
          exec "${themeRoot}/package/bin/reload-theme"
        fi
        exec ${syncTheme}
      '';
      home.file."local/bin/set-theme.sh".source = pkgs.writeShellScript "set-theme.sh" ''
        set -eu
        case "''${1:-}" in
          light|dark|auto) exec noctalia msg theme-mode-set "$1" ;;
          *) echo "Usage: set-theme.sh light|dark|auto" >&2; exit 1 ;;
        esac
      '';
      programs.zsh.shellAliases = {
        stl = "set-theme.sh light";
        std = "set-theme.sh dark";
      };
      home.activation.syncNoctaliaTheme = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
        run mkdir -p ${lib.escapeShellArg themeRoot}
        run ln -sfn ${cfg.package} "${themeRoot}/package"
        run ${syncTheme}
      '';
    }
    (lib.mkIf config.my.programs.powerline.enable {
      my.programs.set-theme.reloadScript = ''
        ${config.my.programs.powerline.package}/bin/powerline-daemon --replace
        if tmux list-sessions >/dev/null 2>&1; then
          ${config.my.programs.powerline.package}/bin/powerline-config tmux setup
          tmux refresh-client -S
        fi
      '';
    })
    (lib.mkIf config.my.programs.emacs.enable {
      my.programs.set-theme.reloadScript = ''
        ${config.my.programs.emacs.package}/bin/emacsclient -e '(load "~/.config/emacs-scripts/load-theme.el")' >/dev/null 2>&1 || true
      '';
    })
  ]);
}
