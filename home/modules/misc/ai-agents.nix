{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.my.programs.ai-agents;
in {
  options.my.programs.ai-agents = {
    enable = mkEnableOption "AI agent profile";
  };

  config = mkIf cfg.enable {
    my.programs.codex.enable = true;
    home.packages = [ pkgs.codex-auth ];
    my.programs.claude-code.enable = true;
    my.programs.ai-agent-common.enable = true;
  };
}
