{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.my.programs.claude-code;
  ccstatusline = pkgs.ccstatusline;
  claude-notify = pkgs.claude-notify;
  notificationsEnabled = false;
in
{
  options.my.programs.claude-code = {
    enable = mkEnableOption "Claude Code";
  };

  config = mkIf cfg.enable {
    programs.claude-code = {
      enable = true;
      settings = {
        permissions.defaultMode = "bypassPermissions";
        includeCoAuthoredBy = false;
        skipDangerousModePermissionPrompt = true;
        statusLine = {
          type = "command";
          command = "${lib.getExe ccstatusline}";
        };
      };
    };

    programs.zsh.shellAliases = {
      cc = "claude";
    };
  };
}
