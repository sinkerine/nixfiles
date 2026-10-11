{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.pi-coding-agent;
  # Orca's orchestration discovery stub is longer than Pi's default limit.
  piCodingAgent = pkgs.pi-coding-agent.overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cd $out/lib/node_modules/pi-monorepo
      sed -i 's/MAX_DESCRIPTION_LENGTH = 1024/MAX_DESCRIPTION_LENGTH = 2048/g; s/MAX_DESCRIPTION_LENGTH=1024/MAX_DESCRIPTION_LENGTH=2048/g; s/MAX_DESCRIPTION_LENGTH2=1024/MAX_DESCRIPTION_LENGTH2=2048/g' \
        dist/core/skills.js dist/bundle/chunks/chunk-*.js
    '';
    postWrapper = (old.postWrapper or "") + ''
      export PI_CODING_AGENT_PACKAGE_ROOT="${placeholder "out"}/lib/node_modules/pi-monorepo"
    '';
  });
  piAstGrep = pkgs.pi-ast-grep;
  piCollapseTools = pkgs.pi-collapse-tools;
  piSubagents = pkgs.pi-subagents;
  piVim = pkgs.pi-vim;
  # This dependency-free extension defaults to summary mode.
  piThinkingSteps = pkgs.fetchFromGitHub {
    owner = "crustyhacker";
    repo = "pi-thinking-steps";
    rev = "2209e03ad13e1eda2c66f5fd7a13932b584c4764"; # v1.0.17
    hash = "sha256-0M9qtHl5QqKMQYM5lfzma1aWW1gwMkB81AdihOk9xLY=";
  };
  piWebAccess = pkgs.pi-web-access;
  piWebAccessConfig = builtins.toJSON {
    provider = "openai";
    openaiSearchProviders = [ "magpie" ];
    openaiUseProviderBaseUrl = true;
    openaiSearchModel = "gpt-6-luna";
    openaiUseAlphaSearch = false;
  };
  piLuna = pkgs.writeShellApplication {
    name = "pi-luna";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model gpt-6-luna "$@"
    '';
  };
  piSol = pkgs.writeShellApplication {
    name = "pi-sol";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model gpt-6.1-sol "$@"
    '';
  };
  piAstra = pkgs.writeShellApplication {
    name = "pi-astra";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model gpt-6-astra "$@"
    '';
  };
in
{
  options.my.programs.pi-coding-agent = {
    enable = mkEnableOption "Pi coding agent";
  };

  config = mkIf cfg.enable {
    programs.pi-coding-agent = {
      enable = true;
      package = piCodingAgent;
      settings = {
        defaultProvider = "magpie";
        defaultModel = "gpt-pi";
        defaultProjectTrust = "always";
        defaultTools = [ "+codemode" ];
        subagents = {
          defaultProvider = "magpie";
          agentOverrides = {
            scout = {
              model = "gpt-6-luna";
              thinking = "low";
            };
            researcher = {
              model = "gpt-6-luna";
              thinking = "medium";
            };
            worker = {
              model = "gpt-6.1-sol";
              thinking = "medium";
            };
            reviewer = {
              model = "gpt-6.1-sol";
              thinking = "high";
            };
            oracle = {
              model = "gpt-6-astra";
              thinking = "high";
            };
            "evidence-auditor" = {
              model = "gpt-6.1-sol";
              thinking = "high";
            };
            delegate = {
              model = "gpt-6-luna";
              thinking = "medium";
            };
          };
        };
        packages = [
          "${piAstGrep}/lib/node_modules/pi-ast-grep"
          "${piCollapseTools}/lib/node_modules/pi-collapse-tools"
          "${piSubagents}/lib/node_modules/pi-subagents"
          "${piThinkingSteps}"
          "${piWebAccess}/lib/node_modules/pi-web-access"
        ];
      };

      models.providers.magpie = {
        baseUrl = "https://magpie-api.sachi.m.mado.moe/v1";
        api = "openai-completions";
        apiKey = "magpie";
        models = [
          {
            id = "gpt-pi";
            name = "GPT-Pi";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "gpt-6-luna";
            name = "GPT-6 Luna";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "gpt-6.1-sol";
            name = "GPT-6.1 Sol";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "gpt-6-astra";
            name = "GPT-6 Astra";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
        ];
      };
    };

    home.sessionVariables.PI_CODING_AGENT_PACKAGE_ROOT = "${piCodingAgent}/lib/node_modules/pi-monorepo";

    home.file.".pi/agent/extensions/pi-vim" = {
      source = "${piVim}/lib/node_modules/pi-vim";
      force = true;
    };
    home.file.".pi/agent/skills/e2e-feature/SKILL.md" = {
      source = ./pi-coding-agent-skills/e2e-feature/SKILL.md;
      force = true;
    };
    xdg.configFile."pi/web-search.json".text = piWebAccessConfig;
    home.file.".pi/agent/keybindings.json".text = builtins.toJSON {
      "app.interrupt" = "ctrl+g";
      "app.editor.external" = [ ];
      "app.clear" = [ ];
    };

    home.packages = [
      piLuna
      piSol
      piAstra
    ];
  };
}
