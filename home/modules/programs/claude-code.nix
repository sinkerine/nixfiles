{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.my.programs.claude-code;
  claude-statusbar = pkgs.claude-statusbar;
  claude-notify = pkgs.claude-notify;
  notificationsEnabled = false;
in
{
  options.my.programs.claude-code = {
    enable = mkEnableOption "Claude Code";
  };

  config = mkIf cfg.enable {
    home.packages = [ claude-statusbar ];

    programs.claude-code = {
      enable = true;
      settings = {
        permissions.defaultMode = "bypassPermissions";
        includeCoAuthoredBy = false;
        skipDangerousModePermissionPrompt = true;
        statusLine = {
          type = "command";
          command = "${lib.getExe claude-statusbar} render";
          refreshInterval = 1;
        };
      };
    };

    programs.zsh.shellAliases = {
      cc = "claude";
    };
  };
}
