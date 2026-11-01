{
  config,
  lib,
  pkgs,
  hostname,
  ...
}:
with lib; let
  cfg = config.my.programs.codex;
  codexModels = {
    sol = "gpt-6.1-sol";
    luna = "gpt-6-luna";
  };
  defaultCodexModelName = "luna";
  defaultCodexModel = "gpt-6-${defaultCodexModelName}";
  notificationsEnabled = false;
  magpieProvider = {
    name = "Magpie";
    base_url = "https://magpie-api.sachi.m.mado.moe/v1";
    wire_api = "responses";
    requires_openai_auth = true;
  };
  magpieProfileSettings = {
    model_provider = "magpie";
    model_providers.magpie = magpieProvider;
  };
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
          } // magpieProfileSettings))
        reasoningEfforts
    )
    codexModels));
  defaultReasoningProfiles = builtins.listToAttrs (map (effort:
      nameValuePair "${defaultCodexModelName}-${effort}" {
        model = defaultCodexModel;
        model_reasoning_effort = effort;
        plan_mode_reasoning_effort = effort;
      } // magpieProfileSettings)
    reasoningEfforts);
  ultraProfiles = mapAttrs' (modelName: model:
    nameValuePair "${modelName}-ultra" ({
      inherit model;
      model_reasoning_effort = "ultra";
      plan_mode_reasoning_effort = "ultra";
    } // magpieProfileSettings))
  codexModels;
  defaultUltraProfile = {
    "${defaultCodexModelName}-ultra" = {
      model = defaultCodexModel;
      model_reasoning_effort = "ultra";
      plan_mode_reasoning_effort = "ultra";
    } // magpieProfileSettings;
  };
  strataProvider = {
    name = "Strata on kazuki";
    base_url = "https://kazuki.m.mado.moe/v1";
    wire_api = "responses";
    stream_idle_timeout_ms = 600000;
    experimental_bearer_token = "lan-only";
  };
  strataProfiles = builtins.listToAttrs (map (effort:
    nameValuePair "strata-${effort}" {
      model = "Qwen3.8-Flash-Next-abliterated-GSQ-RCO-IQ2_XS";
      model_provider = "strata";
      model_context_window = 131072;
      show_raw_agent_reasoning = true;
      model_reasoning_effort = effort;
      plan_mode_reasoning_effort = effort;
      model_providers.strata = strataProvider;
    }) [ "low" "medium" "high" ]);
  codexVariants = defaultReasoningProfiles // defaultUltraProfile // reasoningProfiles // ultraProfiles // strataProfiles;
  # Pass native config overrides so these commands also work with alternate
  # CODEX_HOME directories and app-server, without installing profile files.
  configArgs = prefix: settings: concatLists (mapAttrsToList (key: value:
    let name = if prefix == "" then key else "${prefix}.${key}";
    in if isAttrs value then configArgs name value
       else [ "-c" "${name}=${builtins.toJSON value}" ]
  ) settings);
  wrapperSettings = mapAttrs' (name: value: nameValuePair "cx-${name}" value) codexVariants
    // mapAttrs' (name: _: nameValuePair "cx-${name}" codexVariants."${name}-medium") codexModels
    // { cx = codexVariants."${defaultCodexModelName}-medium"; };
  codexWrappers = mapAttrs (name: settings: pkgs.writeShellScriptBin name ''
    exec ${lib.getExe pkgs.codex-trusted} ${escapeShellArgs (configArgs "" settings)} "$@"
  '') wrapperSettings;
in {
  options.my.programs.codex = {
    enable = mkEnableOption "Codex";
    hooks = mkOption {
      type = types.attrsOf (types.listOf (pkgs.formats.json { }).type);
      default = { };
      description = "Hook matcher groups merged with the existing Codex integrations.";
    };
    wrappers = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      default = codexWrappers;
      description = "Executable Codex model and reasoning variants.";
    };
    enableCLIProxyAPI = mkOption {
      type = types.bool;
      default = true;
      description = "Use Magpie endpoint and API-key auth instead of default Codex auth.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      pkgs.codex-notify
      pkgs.codex-trusted
    ] ++ attrValues codexWrappers;

    home.file = {
      ".codex/hooks.json" = {
        force = true;
        text = builtins.toJSON {
          hooks = cfg.hooks;
        };
      };
    } // optionalAttrs cfg.enableCLIProxyAPI {
      ".codex/auth.json".text = builtins.toJSON {
        OPENAI_API_KEY = "dummykey";
      };
    };

    programs.zsh.shellAliases.codex = "codex-trusted";

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
          model = "gpt-6-luna";
          model_provider = "magpie";
          model_providers.magpie = magpieProvider;
        };
    };

  };
}
