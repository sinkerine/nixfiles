{ config, lib, pkgs, nixinfo, ... }:

with lib;
let
  cfg = config.my.programs.zsh;
  isLinux = pkgs.stdenv.hostPlatform.isLinux;
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  editorValue =
    if config.my.programs.nvim.enable then "nvim"
    else if config.my.programs.emacs.enable then "${config.home.homeDirectory}/local/bin/exec-editor.sh"
    else "vim";
in {
  options.my.programs.zsh = {
    enable = mkEnableOption "Zsh";
    package = mkOption {
      type = types.package;
      default = pkgs.zsh;
      defaultText = literalExpression "pkgs.zsh";
      description = "The zsh package to use.";
    };
    isXorg = mkOption {
      type = types.bool;
      default = false;
      description = "Is XOrg";
    };
  };

  config = mkIf cfg.enable ({
    programs.zsh = {
      enable = true;
      enableCompletion = false;
      zimfw = {
        enable = true;
        modules = [
          "mollifier/cd-gitroot --fpath . --source cd-gitroot.plugin.zsh"
          "jeffreytse/zsh-vi-mode"
          "https://github.com/sinkerine/zce.zsh.git --source zce.plugin.zsh"
          "zsh-users/zsh-autosuggestions"
          "zsh-users/zsh-syntax-highlighting"
        ];
      };

      history = {
        path = "${config.home.homeDirectory}/.zsh_history";
        size = 1000000000;
        save = 1000000000;
        ignoreDups = true;
      };
      sessionVariables = {
        LC_ALL = "en_US.utf-8";
        LANG = "en_US.utf-8";
        LANGUAGE = "en_US.UTF-8";
        NIX_PATH =
          "$HOME/.nix-defexpr/channels:/nix/var/nix/profiles/per-user/root/channels\${NIX_PATH:+:$NIX_PATH}";
        CARGO_HOME = "${config.xdg.cacheHome}/cargo";
        DOOMDIR = "${config.home.homeDirectory}/.doom.d";
      } // optionalAttrs isDarwin { HOMEBREW_NO_AUTO_UPDATE = "1"; };
      # Env vars that are specific to interactive shell.
      initContent = mkMerge [
        (mkBefore ''
          # zmodload zsh/zprof
          export TZ="America/Los_Angeles"
          export PATH="$PATH:$HOME/local/bin:/usr/local/bin:/usr/bin";
          export EDITOR="${editorValue}";
          export TERM="foot";
          export TLDR_COLOR_BLANK="blue";
          export TLDR_COLOR_DESCRIPTION="green";
          export TLDR_COLOR_PARAMETER="blue";
          export ZSH_AUTOSUGGEST_USE_ASYNC=true;
          export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=#a8a8a8,underline";
          export GPG_TTY="$(tty)"
          export KEYTIMEOUT=1
          # Only the chars in this list are skipped in word operations.
          export WORDCHARS='*?_-.[]~=&;!#$%^(){}<>'
          # Only check zcompdump per day
          autoload -Uz compinit
          if [[ -n ~/.zcompdump(#qN.mh+24) ]]; then
            compinit;
          else
            compinit -C;
          fi;

          # This allows us to override the zvm keybindings later.
          # https://github.com/jeffreytse/zsh-vi-mode#initialization-mode
          export ZVM_INIT_MODE=sourcing
        '')
        (mkOrder 650 (builtins.readFile ./zshrc))
        (mkAfter ''
          # Niri's IPC socket contains the compositor PID and changes on restart.
          if (( $+commands[systemctl] )); then
            autoload -Uz add-zsh-hook
            _niri_refresh_socket() {
              local socket
              socket="$(systemctl --user show-environment 2>/dev/null |
                sed -n 's/^NIRI_SOCKET=//p')"
              if [[ -S "$socket" ]]; then
                export NIRI_SOCKET="$socket"
              else
                unset NIRI_SOCKET
              fi
            }
            add-zsh-hook precmd _niri_refresh_socket
            _niri_refresh_socket
          fi
        '')
      ];

      shellAliases = {
        md = "mkdir -p";
        rz =
          "unset __HM_SESS_VARS_SOURCED; unset __HM_ZSH_SESS_VARS_SOURCED; exec $SHELL";
        cdg = "cd-gitroot";
        prl = "parallel";
        grep = "grep --color=auto";
        rp = "realpath";

        # Editors
        ew = "$EDITOR";
        # Misc
        op = (if isLinux then "xdg-open" else "open");
        cpy = config.my.services.clipper.copyCommand;
        pst = (if isLinux then
          (if cfg.isXorg then "xclip -o" else "wl-paste")
        else
          "pbpaste");
        dockerrl = "DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock docker";
      } // optionalAttrs isLinux {
        sc = "sudo systemctl";
        scu = "systemctl --user";
      };
    };
    home.packages = [ pkgs.lua ];
  });
}
