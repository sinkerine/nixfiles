{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.my.programs.codex;
  caveman = pkgs.caveman;
  orcaSkills = pkgs.fetchFromGitHub {
    owner = "stablyai";
    repo = "orca";
    rev = "fa0180dc61a0b1e83ee0aed69555b56a097142aa";
    hash = "sha256-/VW8gMiYbuMxMfIkzlPxJZpq/qVs8rNfx+Iz5yV8mRc=";
  };
  orcaSkillNames = [
    "computer-use"
    "orca-cli"
    "orca-emulator"
    "orca-emulator-android"
    "orca-linear"
    "orca-per-workspace-env"
    "orchestration"
  ];
  orcaSkillFiles = listToAttrs (map (skill:
    nameValuePair ".agents/skills/${skill}" {
      source = "${orcaSkills}/skills/${skill}";
    })
  orcaSkillNames);
  cavemanSkillNamespace = pkgs.linkFarm "caveman-agent-skills" [
    {
      name = "SKILL.md";
      path = "${caveman}/skills/caveman/SKILL.md";
    }
    {
      name = "caveman-commit";
      path = "${caveman}/skills/caveman-commit";
    }
    {
      name = "caveman-help";
      path = "${caveman}/skills/caveman-help";
    }
    {
      name = "caveman-review";
      path = "${caveman}/skills/caveman-review";
    }
    {
      name = "caveman-compress";
      path = "${caveman}/caveman-compress";
    }
  ];
  codexHooksPath = "${config.home.homeDirectory}/.codex/hooks.json";
  orcaCodexHookPath = "${config.home.homeDirectory}/.codex/.orca/agent-hooks/codex-hook.sh";
  orcaCodexHookEvents = [
    "SessionStart"
    "UserPromptSubmit"
    "PreToolUse"
    "PermissionRequest"
    "PostToolUse"
    "SubagentStart"
    "SubagentStop"
    "Stop"
  ];
  toml = pkgs.formats.toml {};
  codexModels = {
    sol = "gpt-6-sol";
    luna = "gpt-6-luna";
  };
  defaultCodexModelName = "luna";
  defaultCodexModel = "gpt-6-${defaultCodexModelName}";
  notificationsEnabled = false;
  reasoningEfforts = [
    "medium"
    "high"
    "xhigh"
    "max"
  ];
  reasoningProfiles = builtins.listToAttrs (flatten (mapAttrsToList (
      modelName: model:
        map (effort:
          nameValuePair "${modelName}-${effort}" ({
            inherit model;
            model_reasoning_effort = effort;
            plan_mode_reasoning_effort = effort;
          }))
        reasoningEfforts
    )
    codexModels));
  defaultReasoningProfiles = builtins.listToAttrs (map (effort:
      nameValuePair "${defaultCodexModelName}-${effort}" {
        model = defaultCodexModel;
        model_reasoning_effort = effort;
        plan_mode_reasoning_effort = effort;
      })
    reasoningEfforts);
  ultraProfiles = mapAttrs' (modelName: model:
    nameValuePair "${modelName}-ultra" ({
      inherit model;
      model_reasoning_effort = "ultra";
      plan_mode_reasoning_effort = "ultra";
    }))
  codexModels;
  defaultUltraProfile = {
    "${defaultCodexModelName}-ultra" = {
      model = defaultCodexModel;
      model_reasoning_effort = "ultra";
      plan_mode_reasoning_effort = "ultra";
    };
  };
  codexProfiles = defaultReasoningProfiles // defaultUltraProfile // reasoningProfiles // ultraProfiles;
  codexProfileFiles = mapAttrs' (profileName: profileSettings:
    nameValuePair ".codex/${profileName}.config.toml" {
      source = toml.generate "${profileName}.config.toml" profileSettings;
    })
  codexProfiles;
  codexProfileAliases = mapAttrs' (profileName: _:
    nameValuePair "cx-${profileName}" "codex-trusted --profile ${profileName}")
  codexProfiles;
in {
  options.my.programs.codex = {
    enable = mkEnableOption "Codex";
    enableCLIProxyAPI = mkOption {
      type = types.bool;
      default = true;
      description = "Use CLIProxyAPI endpoint and API-key auth instead of default Codex auth.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.codex-notify
      pkgs.codex-trusted
    ];

    home.file =
      codexProfileFiles
      // orcaSkillFiles
      // {
        ".codex/.orca/agent-hooks/codex-hook.sh" = {
          executable = true;
          text = ''
            #!/bin/sh
            payload="$(cat)"
            if [ -n "''${ORCA_AGENT_HOOK_ENDPOINT-}" ] && [ -r "$ORCA_AGENT_HOOK_ENDPOINT" ]; then
              . "$ORCA_AGENT_HOOK_ENDPOINT" 2>/dev/null || :
            fi
            [ -n "''${ORCA_AGENT_HOOK_PORT-}" ] || exit 0
            [ -n "''${ORCA_AGENT_HOOK_TOKEN-}" ] || exit 0
            [ -n "''${ORCA_PANE_KEY-}" ] || exit 0
            printf '%s' "$payload" | ${pkgs.curl}/bin/curl -sS -X POST \
              "http://127.0.0.1:$ORCA_AGENT_HOOK_PORT/hook/codex" \
              --connect-timeout 0.5 --max-time 1.5 --noproxy 127.0.0.1 \
              -H "Content-Type: application/x-www-form-urlencoded" \
              -H "X-Orca-Agent-Hook-Token: $ORCA_AGENT_HOOK_TOKEN" \
              --data-urlencode "paneKey=$ORCA_PANE_KEY" \
              --data-urlencode "tabId=''${ORCA_TAB_ID-}" \
              --data-urlencode "launchToken=''${ORCA_AGENT_LAUNCH_TOKEN-}" \
              --data-urlencode "worktreeId=''${ORCA_WORKTREE_ID-}" \
              --data-urlencode "env=''${ORCA_AGENT_HOOK_ENV-}" \
              --data-urlencode "version=''${ORCA_AGENT_HOOK_VERSION-}" \
              --data-urlencode "payload@-" >/dev/null 2>&1 || true
          '';
        };
        ".codex/hooks.json" = {
          force = true;
          text = builtins.toJSON {
            hooks = lib.genAttrs orcaCodexHookEvents (event:
              [
                {
                  hooks = [
                    {
                      type = "command";
                      command = orcaCodexHookPath;
                      timeout = 2;
                    }
                  ];
                }
              ]
              ++ lib.optional (event == "SessionStart") {
                hooks = [
                  {
                    type = "command";
                    command = "echo 'CAVEMAN MODE ACTIVE. Rules: Drop articles/filler/pleasantries/hedging. Fragments OK. Short synonyms. Pattern: [thing] [action] [reason]. [next step]. Not: Sure! I would be happy to help you with that. Yes: Bug in auth middleware. Fix: Code/commits/security: write normal. User says stop caveman or normal mode to deactivate.'";
                    statusMessage = "Loading caveman mode...";
                    timeout = 10;
                  }
                ];
              });
          };
        };
        ".codex/plugins/caveman" = {
          source = "${caveman}/plugins/caveman";
        };
        ".agents/skills/caveman" = {
          source = cavemanSkillNamespace;
        };
        ".agents/skills/manage-docker-services" = {
          source = ./codex-skills/manage-docker-services;
        };
        ".agents/skills/nix-deploy-rs" = {
          source = ./codex-skills/nix-deploy-rs;
        };
        ".agents/skills/orca-skill-discovery" = {
          source = ./codex-skills/orca-skill-discovery;
        };
        ".agents/skills/gui-sandbox" = {
          source = ./codex-skills/gui-sandbox;
        };
      }
      // optionalAttrs cfg.enableCLIProxyAPI {
        ".codex/auth.json".text = builtins.toJSON {
          OPENAI_API_KEY = "sk-dummy";
        };
      };

    programs.zsh.shellAliases =
      {
        codex = "codex-trusted";
        cx = "codex-trusted --profile luna-medium";
      }
      // codexProfileAliases;

    programs.codex = {
      enable = true;
      settings =
        {
          features = {
            hooks = true;
            shell_snapshot = true;
            multi_agent = true;
            apps = true;
            skills = true;
            prevent_idle_sleep = true;
            undo = true;
          };

          history = {
            persistence = "save-all";
            max_bytes = 104857600;
          };

          hooks.state."${codexHooksPath}:session_start:0:0".trusted_hash =
            "sha256:9106e42acfdabf4c89dfa2d44eff9326047a7003afe2ea9ed7ed682f68429135";

          model = defaultCodexModel;
          model_reasoning_effort = "medium";
          plan_mode_reasoning_effort = "high";

          personality = "pragmatic";

          project_root_markers = [
            ".git"
            ".hg"
            ".sl"
          ];

          approval_policy = "never";
          sandbox_mode = "danger-full-access";
          bypass_hook_trust = true;

          tui.status_line = [
            "model-with-reasoning"
            "current-dir"
            "context-remaining"
            "context-used"
            "five-hour-limit"
          ];

        }
        // optionalAttrs notificationsEnabled {
          notify = [(lib.getExe pkgs.codex-notify)];
        }
        // optionalAttrs cfg.enableCLIProxyAPI {
          model_provider = "cliproxyapi";
          model_providers = {
            cliproxyapi = {
              name = "cliproxyapi";
              base_url = "https://cpa.sachi.m.mado.moe/v1";
              wire_api = "responses";
            };
          };
        };
    };

  };
}
