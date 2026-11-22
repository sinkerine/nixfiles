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
  piPerModelSystemPrompt = "${pkgs.pi-per-model-system-prompt}/lib/node_modules/@sinkerine/pi-per-model-system-prompt";
  piBtw = pkgs.pi-btw;
  piGoal = pkgs.pi-goal;
  magpieCodexResponses = {
    api = "openai-responses";
    compat = {
      supportsMidConvoSystemMessages = true;
      supportsAdditionalTools = true;
      supportsMidConvoEffort = true;
      supportsStrictMode = true;
      supportsOpenAIGrammarTools = true;
    };
  };
  magpieGeminiResponses = {
    api = "openai-responses";
    compat = {
      supportsMidConvoSystemMessages = true;
    };
    thinkingLevelMap = {
      off = null;
      minimal = null;
      low = "low";
      medium = "medium";
      high = "high";
      xhigh = "xhigh";
      max = null;
    };
  };
  magpieClaudeMessages = {
    api = "anthropic-messages";
    baseUrl = "https://magpie-api.sachi.m.mado.moe";
    compat = {
      forceAdaptiveThinking = true;
      supportsTemperature = false;
      supportsMidConvoSystemMessages = true;
      supportsMidConvoEffort = true;
      supportsStrictTools = true;
    };
    thinkingLevelMap = {
      off = null;
      minimal = null;
      low = "low";
      medium = "medium";
      high = "high";
      xhigh = "xhigh";
      max = "max";
    };
  };
  magpieAgyClaudeMessages = magpieClaudeMessages // {
    thinkingLevelMap = {
      off = null;
      minimal = null;
      low = "low";
      medium = "medium";
      high = "high";
      xhigh = null;
      max = null;
    };
  };
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
  qexWaitExtension = pkgs.writeTextFile {
    name = "qex-wait.ts";
    text = builtins.replaceStrings
      [ "@SUBAGENTS@" "@QEX@" ]
      [ "${piSubagents}/lib/node_modules/pi-subagents" "${pkgs.qex}" ]
      (builtins.readFile ./pi-coding-agent-extensions/qex-wait.ts);
    checkPhase = ''
      PI_TEST_PACKAGE=${piSubagents}/lib/node_modules/pi-subagents \
        QEX_WAIT_EXTENSION=$out \
        ${pkgs.nodejs}/bin/node --test ${./pi-coding-agent-extensions/qex-wait.test.mjs}
    '';
  };
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
      exec pi --provider magpie --model group/sol "$@"
    '';
  };
  piSolJb = pkgs.writeShellApplication {
    name = "pi-sol-jb";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/sol-6.1 "$@"
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
  piGeminiSpeed = pkgs.writeShellApplication {
    name = "pi-gemini-speed";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/gemini-speed "$@"
    '';
  };
  piOpus = pkgs.writeShellApplication {
    name = "pi-opus";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/opus "$@"
    '';
  };
  piAgyOpus = pkgs.writeShellApplication {
    name = "pi-agy-opus";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --provider magpie --model group/agy-opus "$@"
    '';
  };
  piQwen = pkgs.writeShellApplication {
    name = "pi-qwen";
    runtimeInputs = [ piCodingAgent ];
    text = ''
      exec pi --no-extensions --provider strata --model qwen3.6-35b-a3b-uncensored-iq4_xs "$@"
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
    mcpServers = mkOption {
      type = types.attrsOf (pkgs.formats.json { }).type;
      default = { };
      description = "MCP servers configured for Pi.";
    };
  };

  config = mkIf cfg.enable {
    my.programs.pi-coding-agent.mcpServers.octoprint.url =
      "https://octoprint-mcp.sachi.m.mado.moe/mcp";

    home.file."${config.programs.pi-coding-agent.configDir}/mcp.json".text = builtins.toJSON {
      inherit (cfg) mcpServers;
    };

    programs.pi-coding-agent = {
      enable = true;
      package = piCodingAgent;
      settings = {
        defaultProvider = "magpie";
        defaultModel = "group/sol";
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
          # Foreground children do not load ambient Pi extensions.
          defaultSubagentOnlyExtensions = [
            "${piPerModelSystemPrompt}/extensions/per-model-system-prompt.ts"
          ];
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
              model = "group/sol";
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
              model = "group/sol";
              thinking = "high";
            };
            delegate = {
              model = "group/sol";
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
          piPerModelSystemPrompt
          "${piSubagents}/lib/node_modules/pi-subagents"
          "${piWebAccess}/lib/node_modules/pi-web-access"
          "${piBtw}/lib/node_modules/@sinkerine/pi-btw"
        ];
      };

      models.providers.magpie = {
        baseUrl = "https://magpie-api.sachi.m.mado.moe/v1";
        api = "openai-completions";
        apiKey = "dummykey";
        compat = {
          promptCacheKeyMode = "enabled";
        };
        models = [
          (magpieCodexResponses // {
            id = "gpt-6-luna";
            name = "GPT-6 Luna";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          })
          (magpieCodexResponses // {
            id = "group/sol";
            name = "Sol";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 500000;
            maxTokens = 128000;
          })
          (magpieCodexResponses // {
            id = "group/sol-6.1";
            name = "sol-jb";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          })
          (magpieCodexResponses // {
            id = "group/astra";
            name = "GPT-6 Astra";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
            maxTokens = 128000;
          })
          (magpieGeminiResponses // {
            id = "group/gemini";
            name = "Gemini";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1048576;
            maxTokens = 65536;
          })
          (magpieGeminiResponses // {
            id = "group/gemini-speed";
            name = "Gemini 4 Hydrogen";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1048576;
            maxTokens = 65536;
          })
          (magpieClaudeMessages // {
            id = "group/fable";
            name = "Claude Fable 5.2";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1000000;
            maxTokens = 128000;
          })
          (magpieClaudeMessages // {
            id = "group/opus";
            name = "Opus";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1000000;
            maxTokens = 128000;
          })
          (magpieAgyClaudeMessages // {
            id = "group/agy-opus";
            name = "AGY Opus 5.5";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1000000;
            maxTokens = 128000;
          })
          (magpieCodexResponses // {
            id = "group/luna-fast";
            name = "Luna Fast";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 1050000;
          })
          (magpieCodexResponses // {
            id = "group/sol-fast";
            name = "Sol Fast";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 500000;
          })
          (magpieCodexResponses // {
            id = "group/sol-ultrafast";
            name = "Sol UltraFast";
            reasoning = true;
            input = [ "text" "image" ];
            contextWindow = 500000;
          })
        ];
      };

      models.providers.strata = {
        baseUrl = "https://strata.kazuki.m.mado.moe/v1";
        api = "openai-completions";
        apiKey = "lan-only";
        compat = {
          supportsDeveloperRole = false;
          supportsReasoningEffort = false;
          supportsStore = false;
          supportsStrictMode = false;
          thinkingFormat = "qwen-chat-template";
        };
        models = [
          {
            id = "qwen3.6-35b-a3b-uncensored-iq4_xs";
            name = "Qwen3.6 35B-A3B Uncensored IQ4_XS";
            reasoning = true;
            input = [ "text" ];
            contextWindow = 131072;
            maxTokens = 16384;
            cost = {
              input = 0;
              output = 0;
              cacheRead = 0;
              cacheWrite = 0;
            };
            thinkingLevelMap = {
              off = null;
              minimal = null;
              low = "low";
              medium = "medium";
              high = "high";
              xhigh = null;
              max = null;
            };
            # Qwen3.6-35B-A3B precise-coding sampling defaults (presence_penalty 0 avoids corrupting tool/code output).
            samplingParams = {
              temperature = 0.6;
              top_p = 0.95;
              top_k = 20;
              presence_penalty = 0.0;
            };
            samplingParamsByThinkingLevel = {
              off = {
                temperature = 0.7;
                top_p = 0.8;
                top_k = 20;
                presence_penalty = 0.0;
              };
            };
          }
        ];
      };
    };

    # Replace links left by older generations that pointed directly into the store.
    home.file."${config.programs.pi-coding-agent.configDir}/models.json".force = true;

    home.file."${config.programs.pi-coding-agent.configDir}/model-prompts.json".text = builtins.toJSON {
      rules = [
        {
          id = "openai-sol";
          match = [
            "magpie/group/sol"
            "magpie/group/sol-fast"
            "magpie/group/sol-ultrafast"
            "gpt-6.2-sol"
          ];
          file = "${./pi-coding-agent-prompts/sol.md}";
        }
        {
          id = "sol-jb";
          match = [ "magpie/group/sol-6.1" ];
          mode = "replace";
          override = true;
          file = "${./pi-coding-agent-prompts/sol-jb.md}";
        }
      ];
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
    home.file.".pi/agent/extensions/qex-wait.ts" = {
      source = qexWaitExtension;
      force = true;
    };
    home.file.".pi/agent/skills/e2e-feature" = {
      source = ./pi-coding-agent-skills/e2e-feature;
      recursive = true;
      force = true;
    };
    home.file.".pi/agent/extensions/e2e-feature-routing.ts" = {
      source = ./pi-coding-agent-extensions/e2e-feature-routing.ts;
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
      recall.timeoutMs = 5000;
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
      piSolJb
      piAstra
      piGemini
      piGeminiSpeed
      piSolFast
      piOpus
      piAgyOpus
      piLunaFast
      piQwen
      # Moves active workspace agent tabs between hosts; also provides the e2e-dispatch alias
      # that the e2e-feature skill uses to register runs.
      pkgs.workspace-dispatch
      e2eFeatureRun
      e2eReviewBenchmark
    ] ++ optional config.my.programs.claude-code.enable claudeReviewer;
  };
}
