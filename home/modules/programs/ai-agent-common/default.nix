{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.my.programs.ai-agent-common;
  agentsTemplate = builtins.readFile ./agents-template.md;
in {
  options.my.programs.ai-agent-common = {
    enable = mkEnableOption "AI agent common configuration";
  };

  config = mkIf cfg.enable {
    home.file.".codex/AGENTS.md".text = agentsTemplate;
    home.file.".claude/CLAUDE.md".text = agentsTemplate;
    home.file.".pi/agent/AGENTS.md" = mkIf config.my.programs.pi-coding-agent.enable {
      text = agentsTemplate;
    };
  };
}
