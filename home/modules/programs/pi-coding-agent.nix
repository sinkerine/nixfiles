{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.my.programs.pi-coding-agent;
  piCodingAgent = pkgs.pi-coding-agent.overrideAttrs (old: {
    postWrapper = (old.postWrapper or "") + ''
      export PI_CODING_AGENT_PACKAGE_ROOT="${placeholder "out"}/lib/node_modules/pi-monorepo"
    '';
    # pi-goal waits for the soonest magpie quota reset after a usage limit.
    postFixup = (old.postFixup or "") + ''
      wrapProgram $out/bin/pi \
        --set-default PI_GOAL_QUOTA_URL https://magpie.sachi.m.mado.moe/api/usage/quotas
    '';
  });
  piAskUser = pkgs.pi-ask-user;
  piFooter = pkgs.pi-footer;
  piAstGrep = pkgs.pi-ast-grep;
  piCollapseTools = pkgs.pi-collapse-tools;
  piSubagents = pkgs.pi-subagents;
  piBtw = pkgs.pi-btw;
  piGoal = pkgs.pi-goal;
  e2eFeatureRun = pkgs.writeShellApplication {
    name = "e2e-feature-run";
    runtimeInputs = [ pkgs.python3 pkgs.git pkgs.bash ];
    text = ''
      exec python3 -B ${./pi-coding-agent-skills/e2e-feature/scripts}/verify.py "$@"
    '';
  };
  e2eReviewBenchmark = pkgs.writeShellApplication {
    name = "e2e-review-benchmark";
    runtimeInputs = [ pkgs.python3 pkgs.git piCodingAgent ];
    text = ''
      exec python3 -B ${./pi-coding-agent-skills/e2e-feature/scripts}/benchmark.py \
        --pi ${piCodingAgent}/bin/pi \
        --manifest ${./pi-coding-agent-skills/e2e-feature/benchmarks/review-cases.json} "$@"
    '';
  };
  e2eVerificationExtension = pkgs.writeText "e2e-verification.ts" (
    builtins.replaceStrings
      [ "@SUBAGENTS@" "@E2E_RUNNER@" ]
      [ "${piSubagents}/lib/node_modules/pi-subagents" "${e2eFeatureRun}" ]
      (builtins.readFile ./pi-coding-agent-extensions/e2e-verification.ts)
  );
  piHindsight = pkgs.pi-hindsight;
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
      exec pi --provider magpie --model group/astra "$@"
    '';
  };
  piSolFast = pkgs.writeShellApplication {
    name = "pi-sol-fast";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/sol-fast "$@"
    '';
  };
  piLunaFast = pkgs.writeShellApplication {
    name = "pi-luna-fast";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/luna-fast "$@"
    '';
  };
  piGemini = pkgs.writeShellApplication {
    name = "pi-gemini";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/gemini "$@"
    '';
  };
  piOpus = pkgs.writeShellApplication {
    name = "pi-opus";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/opus "$@"
    '';
  };
  # pi-subagents' claude-code adapter owns its argv, so the reviewer's model
  # and effort are pinned in the command it launches.
  claudeReviewer = pkgs.writeShellApplication {
    name = "claude-reviewer";
    text = ''
      exec claude --model claude-opus-5-5 --effort medium "$@"
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
        defaultModel = "gpt-6.1-sol";
        defaultThinkingLevel = "medium";
        tuiMode = "regular";
        defaultProjectTrust = "always";
        compaction = {
          enabled = true;
          # Reserve 40% so each configured model compacts above 60% usage.
          modelOverrides = listToAttrs (concatLists (mapAttrsToList
            (provider: providerConfig: map (model: {
              name = "${provider}/${model.id}";
              value.reserveTokens = builtins.div (model.contextWindow * 40) 100;
            }) providerConfig.models)
            config.programs.pi-coding-agent.models.providers));
        };
        defaultTools = [
          "+codemode"
          "+grep"
          "+find"
        ];
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
              model = "group/gemini";
              thinking = "high";
              toolBudget = {
                soft = 8;
                hard = 12;
                block = "*";
              };
            };
            oracle = {
              model = "group/astra";
              thinking = "high";
            };
            "evidence-auditor" = {
              model = "gpt-6.1-sol";
              thinking = "high";
            };
            delegate = {
              model = "gpt-6.1-sol";
              thinking = "medium";
            };
          };
        };
        packages = [
          "${piAskUser}/lib/node_modules/pi-ask-user"
          "${piFooter}/lib/node_modules/@smoose/pi-footer"
          "${piAstGrep}/lib/node_modules/pi-ast-grep"
          "${piCollapseTools}/lib/node_modules/pi-collapse-tools"
          "${piGoal}/lib/node_modules/pi-goal"
          "${piHindsight}/lib/node_modules/pi-hindsight-memory"
          "${piSubagents}/lib/node_modules/pi-subagents"
          "${piWebAccess}/lib/node_modules/pi-web-access"
          "${piBtw}/lib/node_modules/@sinkerine/pi-btw"
        ];
      };

      models.providers.magpie = {
        baseUrl = "https://magpie-api.sachi.m.mado.moe/v1";
        api = "openai-completions";
        apiKey = "dummykey";
        models = [
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
            id = "group/astra";
            name = "GPT-6 Astra";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          }
          {
            id = "group/gemini";
            name = "Gemini 4 Hydrogen";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1048576;
            maxTokens = 65536;
          }
          {
            id = "group/fable";
            name = "Claude Fable 5.2";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1000000;
            maxTokens = 128000;
          }
          {
            id = "group/opus";
            name = "Opus";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1000000;
            maxTokens = 128000;
          }
          {
            id = "group/luna-fast";
            name = "Luna Fast";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
          }
          {
            id = "group/sol-fast";
            name = "Sol Fast";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
          }
        ];
      };
    };

    home.sessionVariables.PI_CODING_AGENT_PACKAGE_ROOT = "${piCodingAgent}/lib/node_modules/pi-monorepo";

    home.file.".pi/agent/extensions/bash-timeout.ts" = {
      source = ./pi-coding-agent-extensions/bash-timeout.ts;
      force = true;
    };

    home.file.".pi/agent/extensions/e2e-verification.ts" = {
      source = e2eVerificationExtension;
      force = true;
    };
    home.file.".pi/agent/skills/e2e-feature" = {
      source = ./pi-coding-agent-skills/e2e-feature;
      recursive = true;
      force = true;
    };
    home.file.".pi/agent/skills/pi-artifacts/SKILL.md" = {
      source = ./pi-coding-agent-skills/pi-artifacts/SKILL.md;
      force = true;
    };
    home.file.".pi/agent/skills/merge-and-archive/SKILL.md" = {
      source = ./pi-coding-agent-skills/merge-and-archive/SKILL.md;
      force = true;
    };
    home.file.".pi/agent/skills/merge-push-and-archive/SKILL.md" = {
      source = ./pi-coding-agent-skills/merge-push-and-archive/SKILL.md;
      force = true;
    };
    home.file.".pi/agent/skills/dispatch-workspaces/SKILL.md" = {
      source = ./pi-coding-agent-skills/dispatch-workspaces/SKILL.md;
      force = true;
    };
    home.file.".pi/agent/skills/return-workspaces/SKILL.md" = {
      source = ./pi-coding-agent-skills/return-workspaces/SKILL.md;
      force = true;
    };
    # Runs through pi-subagents' claude-code adapter, which needs the claude CLI.
    home.file.".pi/agent/agents/claude-reviewer.md" = mkIf config.my.programs.claude-code.enable {
      source = ./pi-coding-agent-agents/claude-reviewer.md;
      force = true;
    };
    xdg.configFile."pi/web-search.json".text = piWebAccessConfig;
    xdg.configFile."pi/settings.json".text = builtins.toJSON {
      footer = {
        preset = "ascii";
        separator = "ascii";
      };
    };
    home.file.".pi/agent/hindsight-memory.json".text = builtins.toJSON {
      apiUrl = "https://hindsight-engineer-api.sachi.m.mado.moe";
      bankId = "pi";
      subagents = "off";
      digest.maxTokens = 800;
      recall.policy = "smart";
      retain.auto = true;
    };
    home.file.".pi/agent/keybindings.json".text = builtins.toJSON {
      "app.interrupt" = "ctrl+g";
      "app.editor.external" = [ ];
      "app.clear" = [ ];
    };

    home.packages = [
      piLuna
      piSol
      piAstra
      piGemini
      piSolFast
      piOpus
      piLunaFast
      # Moves active workspace agent tabs between hosts; also provides the e2e-dispatch alias
      # that the e2e-feature skill uses to register runs.
      pkgs.workspace-dispatch
      e2eFeatureRun
      e2eReviewBenchmark
    ] ++ optional config.my.programs.claude-code.enable claudeReviewer;
  };
}
