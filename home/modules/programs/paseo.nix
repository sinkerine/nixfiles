{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.programs.paseo;
  healthUrl = "http://${lib.replaceStrings [ "0.0.0.0" ] [ "127.0.0.1" ] cfg.daemon.listen}/api/health";
  waitForDaemon = pkgs.writeShellScript "paseo-wait-ready" ''
    for attempt in $(${pkgs.coreutils}/bin/seq 1 120); do
      # HTTP starts before built-in plugins finish. Wait for the supervisor's
      # readiness record too, so the GUI sees the complete provider registry.
      if ${pkgs.curl}/bin/curl --silent --fail --max-time 1 ${lib.escapeShellArg healthUrl} > /dev/null &&
        ${pkgs.coreutils}/bin/timeout 3 ${lib.getExe cfg.package} daemon status --json |
          ${pkgs.jq}/bin/jq --exit-status '.localDaemon == "running"' > /dev/null; then
        exit 0
      fi
      ${pkgs.coreutils}/bin/sleep 0.5
    done
    echo "Paseo daemon did not become ready; see journalctl --user -u paseo" >&2
    exit 1
  '';
  desktopLauncher = pkgs.writeShellScriptBin "paseo-desktop" ''
    set -e
    ${pkgs.systemd}/bin/systemctl --user start paseo.service
    ${waitForDaemon}
    exec ${lib.getExe cfg.desktop.package} "$@"
  '';
  skillNames = [
    "paseo"
    "paseo-advisor"
    "paseo-committee"
    "paseo-handoff"
    "paseo-help"
    "paseo-plugin"
  ];
  skillFiles =
    directory:
    lib.listToAttrs (
      map (
        name:
        lib.nameValuePair "${directory}/${name}" {
          source = "${cfg.package}/lib/paseo/packages/server/dist/server/skills/${name}";
        }
      ) skillNames
    );
  hookGroups =
    provider: events:
    lib.genAttrs events (event: [
      {
        matcher = "";
        hooks = [
          {
            type = "command";
            command = ''if [ -n "$PASEO_TERMINAL_ID" ]; then ${lib.getExe cfg.package} hooks ${provider} ${event}; fi'';
            timeout = 10;
          }
        ];
      }
    ]);
  openCodeHook = pkgs.runCommand "paseo-opencode-hook" { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    node --input-type=module -e '
      import { OPENCODE_PLUGIN_SOURCE } from "${cfg.package}/lib/paseo/packages/server/dist/server/terminal/agent-hooks/opencode/opencode-plugin.js";
      process.stdout.write(OPENCODE_PLUGIN_SOURCE.replaceAll(JSON.stringify("paseo"), JSON.stringify("${lib.getExe cfg.package}")));
    ' > $out
  '';
in
{
  options.my.programs.paseo = {
    enable = lib.mkEnableOption "Paseo, an interface for AI coding agents";

    package = lib.mkPackageOption pkgs "paseo" { };

    integrations.enable = lib.mkEnableOption "declarative Paseo skills, MCP, and all supported agent hooks";

    mcpUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:6767/mcp/agents";
      description = "Paseo orchestration MCP endpoint for local agent clients.";
    };

    daemon = {
      hostnames = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional Host headers accepted through the reverse proxy.";
      };
      enable = lib.mkEnableOption "the Paseo background daemon";
      listen = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1:6767";
        description = "Listen address for the user daemon.";
      };
    };

    desktop = {
      enable = lib.mkEnableOption "the Paseo desktop app, which manages its own daemon";
      package = lib.mkPackageOption pkgs "paseo-desktop" { };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        home.packages = [ cfg.package ]
          ++ lib.optional cfg.desktop.enable cfg.desktop.package
          ++ lib.optional (cfg.desktop.enable && cfg.daemon.enable) (lib.hiPrio desktopLauncher);
      }
      (lib.mkIf (cfg.desktop.enable && cfg.daemon.enable) {
        # Keep desktop preferences writable while giving systemd sole daemon ownership.
        home.activation.paseoDaemonOwnership = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          settings=${lib.escapeShellArg "${config.xdg.configHome}/Paseo/desktop-settings.json"}
          run ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$settings")"
          if [ -f "$settings" ]; then
            document="$(${pkgs.coreutils}/bin/cat "$settings")"
          else
            document='{"version":1,"settings":{},"migrations":{}}'
          fi
          updated="$(printf '%s' "$document" | ${pkgs.jq}/bin/jq '
            .settings.daemon.manageBuiltInDaemon = false |
            .settings.daemon.keepRunningAfterQuit = true |
            .migrations.legacyRendererSettingsImported = true |
            .migrations.daemonStopOnQuitDefaultApplied = true')"
          temporary="$(${pkgs.coreutils}/bin/mktemp "$settings.XXXXXX")"
          printf '%s\n' "$updated" > "$temporary"
          run ${pkgs.coreutils}/bin/mv "$temporary" "$settings"
        '';
      })
      (lib.mkIf cfg.desktop.enable {
        # Resolve through the active profile even when the app menu retains an old PATH.
        xdg.desktopEntries.paseo-desktop = {
          name = "Paseo";
          genericName = "AI Coding Agents";
          comment = "Self-hosted daemon for AI coding agents";
          exec = ''"${config.home.profileDirectory}/bin/${cfg.desktop.package.meta.mainProgram or "paseo-desktop"}"'';
          icon = "paseo-desktop";
          categories = [ "Development" ];
          terminal = false;
          settings.StartupWMClass = "paseo-desktop";
        };
      })
      (lib.mkIf cfg.daemon.enable {
        systemd.user.services.paseo = {
          Unit = {
            Description = "Paseo coding agent daemon";
            After = [ "network.target" ];
          };
          Service = {
            Type = "exec";
            ExecStartPost = "${waitForDaemon}";
            TimeoutStartSec = 90;
            WorkingDirectory = config.home.homeDirectory;
            ExecStart = "${lib.getExe cfg.package} daemon run";
            Environment = [
              "PASEO_HOME=${config.home.homeDirectory}/.paseo"
              "PASEO_LISTEN=${cfg.daemon.listen}"
              "PASEO_HOSTNAMES=${lib.concatStringsSep "," cfg.daemon.hostnames}"
              "PATH=${config.home.profileDirectory}/bin:/run/wrappers/bin:/run/current-system/sw/bin"
            ];
            Restart = "on-failure";
            RestartSec = 5;
            TimeoutStopSec = 30;
          };
          Install.WantedBy = [ "default.target" ];
        };
      })
      (lib.mkIf cfg.integrations.enable (
        lib.mkMerge [
          (lib.mkIf config.my.programs.claude-code.enable {
            home.file = skillFiles ".claude/skills";
            programs.claude-code.mcpServers.paseo = {
              type = "http";
              url = cfg.mcpUrl;
            };
            programs.claude-code.settings.hooks = hookGroups "claude" [
              "UserPromptSubmit"
              "Stop"
              "StopFailure"
              "SessionEnd"
              "Notification"
            ];
          })
          (lib.mkIf config.my.programs.codex.enable {
            home.file = skillFiles ".agents/skills";
            programs.codex.settings.mcp_servers.paseo.url = cfg.mcpUrl;
            my.programs.codex.hooks = hookGroups "codex" [
              "UserPromptSubmit"
              "PreToolUse"
              "PostToolUse"
              "PermissionRequest"
              "Stop"
            ];
          })
          (lib.mkIf config.my.programs.pi-coding-agent.enable {
            home.file = skillFiles ".pi/agent/skills" // {
              ".pi/agent/mcp.json".text = builtins.toJSON {
                mcpServers.paseo.url = cfg.mcpUrl;
              };
            };
          })
          (lib.mkIf config.my.programs.opencode.enable {
            xdg.configFile."opencode/plugins/paseo-terminal-activity.js".source = openCodeHook;
          })
        ]
      ))
    ]
  );
}
