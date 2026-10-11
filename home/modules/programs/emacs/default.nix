{ config, pkgs, lib, mylib, state, ... }:

with lib;
let
  cfg = config.my.programs.emacs;
  inherit (mylib) templateFile writeShellScriptFile;
  templateData = { inherit (state) theme; };
in {
  options.my.programs.emacs = {
    enable = mkEnableOption "emacs";
    package = mkOption {
      type = types.package;
      default = pkgs.emacs-nox;
    };
    enableSSHConfigRepo =
      mkEnableOption "use ssh url for the git emacs config repo";
    startAfterGraphicalSession =
      mkEnableOption "start after systemd graphical-session.target";
    extraOptions = mkOption {
      type = with types; listOf str;
      default = [ ];
      example = [ "-f" "exwm-enable" ];
      description = ''
        For service: Extra command-line arguments to pass to <command>emacs</command>.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      programs.emacs = {
        enable = true;
        inherit (cfg) package;
      };
      services.emacs = {
        enable = true;
        startWithUserSession = !cfg.startAfterGraphicalSession;
        inherit (cfg) extraOptions;
      };

      home.file."local/bin/exec-editor.sh".source =
        writeShellScriptFile "exec-editor.sh" ./exec-editor.sh;
      xdg.configFile."emacs-scripts/load-theme.el".source =
        templateFile "emacs-scripts-load-theme.el" templateData
        ./scripts/load-theme.el.jinja;

      home.activation.gitCloneDoomemacs =
        hm.dag.entryAfter [ "writeBoundary" ] ''
          if ! [ -d $HOME/.emacs.d ]; then
            ${pkgs.git}/bin/git clone https://github.com/doomemacs/doomemacs.git $HOME/.emacs.d
          fi
        '';

      # Change the remote url after git clone to avoid dependency on `ssh` when cloning.
      home.activation.gitCloneEmacsConfig = let
        changeRemoteCmd = optionalString cfg.enableSSHConfigRepo
          "${pkgs.git}/bin/git remote set-url origin git@github.com:sinkerine/doomemacs-config.git";
      in hm.dag.entryAfter [ "writeBoundary" ] ''
        if ! [ -d $HOME/.doom.d ]; then
            ${pkgs.git}/bin/git clone https://github.com/sinkerine/doomemacs-config.git $HOME/.doom.d
            cd $HOME/.doom.d
            ${changeRemoteCmd}
        fi
      '';
    }
    (mkIf cfg.startAfterGraphicalSession {
      systemd.user.services.emacs = {
        Unit = {
          After = [ "graphical-session-pre.target" ];
          PartOf = [ "graphical-session.target" ];
        };
        Install = { WantedBy = [ "graphical-session.target" ]; };
      };
    })
  ]);
}
