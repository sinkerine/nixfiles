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
  orcaHookEvents = [
    "SessionStart"
    "SessionEnd"
    "UserPromptSubmit"
    "Stop"
    "StopFailure"
    "SubagentStart"
    "SubagentStop"
    "TeammateIdle"
    "PreToolUse"
    "PostToolUse"
    "PostToolUseFailure"
    "PermissionRequest"
    "PostCompact"
  ];
  # Capture Claude's PID before the managed hook inserts another shell.
  orcaHookCommand = ''if [ -x "''${HOME-}/.orca/agent-hooks/claude-hook.sh" ]; then ORCA_HOOK_AGENT_PID="''${PPID:-}"; export ORCA_HOOK_AGENT_PID; /bin/sh "''${HOME-}/.orca/agent-hooks/claude-hook.sh"; else cat >/dev/null; printf '{}\n'; fi'';
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
        hooks = lib.genAttrs orcaHookEvents (event: [
          {
            hooks = [
              {
                type = "command";
                command = orcaHookCommand;
                timeout = 10;
              }
            ];
          }
        ]);
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
