{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.programs.zsh.zimfw;
in
{
  options.programs.zsh.zimfw = {
    enable = mkEnableOption "Zim";
    modules = mkOption {
      type = with types; listOf str;
      default = [ ];
      description = "List of Zim modules";
    };
    package = mkOption {
      type = types.package;
      default = pkgs.zimfw;
    };
    zimHome = mkOption {
      type = types.path;
      default = "${config.home.homeDirectory}/.local/share/zim";
      defaultText = "~/.local/share/zim";
    };
    zimConfigFile = mkOption {
      type = types.path;
      default = "${config.home.homeDirectory}/.zimrc";
      defaultText = "~/.zimrc";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];
    home.file.${cfg.zimConfigFile}.text = ''
      ${optionalString (cfg.modules != [ ]) ''
        ${concatStringsSep "\n" (map (m: "zmodule ${m}") cfg.modules)}
      ''}
    '';
    home.activation.zimfwInit = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export ZIM_HOME=${escapeShellArg (toString cfg.zimHome)}
      export ZIM_CONFIG_FILE=${escapeShellArg (toString cfg.zimConfigFile)}
      # Zim checks .zdegit before reinstalling, so repair the old GitHub
      # owner metadata first. The module contents are unchanged by this rename.
      zce_zdegit="$ZIM_HOME/modules/zce.zsh/.zdegit"
      if [[ -f "$zce_zdegit" ]] && [[ "$(head -n 1 "$zce_zdegit")" == "https://github.com/15cm/zce.zsh.git" ]]; then
        ${pkgs.gnused}/bin/sed -i '1s#^https://github.com/15cm/zce.zsh.git$#https://github.com/sinkerine/zce.zsh.git#' "$zce_zdegit"
      fi
      if ! ${pkgs.zsh}/bin/zsh -c "source ${cfg.package}/zimfw.zsh init -q"; then
        # Reinstall modules whose recorded origin changed, such as after a
        # repository owner rename. Zim's quiet reinstall repairs stale
        # .zdegit metadata without requiring an interactive shell command.
        ${pkgs.zsh}/bin/zsh -c "source ${cfg.package}/zimfw.zsh reinstall -q"
        ${pkgs.zsh}/bin/zsh -c "source ${cfg.package}/zimfw.zsh init -q"
      fi
    '';
    programs.zsh.initContent = mkOrder 550 ''
      export ZIM_HOME=${cfg.zimHome};
      export ZIM_CONFIG_FILE=${cfg.zimConfigFile};
      zstyle ':zim:zmodule' use 'degit'
      source $ZIM_HOME/init.zsh
    '';
  };
}
