{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.services.orca;
  orcaSettings = pkgs.writeText "orca-settings.json" (builtins.toJSON {
    settings = {
      # Keep these settings shared between GUI and headless Orca hosts.
      theme = "dark";
      disabledTuiAgents = [
        "claude"
        "claude-agent-teams"
      ];
      agentCmdOverrides = {
        codex = "cx-luna-medium";
      };
      agentStatusHooksEnabled = true;
      agentDefaultArgs = {
        claude = "--dangerously-skip-permissions";
        "claude-agent-teams" = "--dangerously-skip-permissions";
        openclaude = "--dangerously-skip-permissions";
        codex = "";
        gemini = "--yolo";
        antigravity = "--dangerously-skip-permissions";
        aider = "--yes-always";
        amp = "--dangerously-allow-all";
        kiro = "--trust-all-tools";
        crush = "--yolo";
        autohand = "--unrestricted";
        cline = "--auto-approve true";
        "command-code" = "--yolo";
        continue = "--allow \"*\"";
        cursor = "--yolo";
        kimi = "--yolo";
        "mistral-vibe" = "--agent auto-approve";
        "qwen-code" = "--approval-mode yolo";
        rovo = "--yolo";
        hermes = "--yolo";
        copilot = "--yolo";
        grok = "--permission-mode bypassPermissions";
        devin = "--permission-mode bypass";
        ante = "--yolo";
      };
    };
  });
  mergeOrcaSettings = pkgs.writeShellScript "merge-orca-settings" ''
    set -euo pipefail

    target="$HOME/.config/orca/profiles/local-default/orca-data.json"
    defaults=${orcaSettings}
    mkdir -p "$(dirname "$target")"

    if [ -f "$target" ]; then
      tmp="$target.tmp.$$"
      ${pkgs.jq}/bin/jq --arg codexCommand cx-luna-medium -s '
        def deepmerge(a; b):
          if (a | type) == "object" and (b | type) == "object" then
            reduce (b | keys_unsorted[]) as $key
              (a;
                .[$key] = if has($key)
                  then deepmerge(.[$key]; b[$key])
                  else b[$key]
                end)
          else b
          end;

        . as $documents
        | deepmerge($documents[0]; $documents[1])
        | .settings.agentCmdOverrides.codex = $codexCommand
        | .settings.agentDefaultArgs.codex = ""
      ' "$target" "$defaults" > "$tmp"
      chmod --reference="$target" "$tmp"
      mv "$tmp" "$target"
    else
      cp "$defaults" "$target"
    fi
  '';
  orcaCli = pkgs.writeShellScriptBin "orca" ''
    set -euo pipefail
    # Resolve the active profile target instead of capturing cfg.package's
    # store path. This keeps the CLI usable after a Nix/Home Manager switch,
    # while an already-installed wrapper remains unchanged.
    if ! cli_command="$(command -v orca-ide-cli)"; then
      echo "orca: unable to find orca-ide-cli in PATH" >&2
      exit 127
    fi
    exec "$cli_command" "$@"
  '';
  serveArgs = [
    "serve"
    "--port"
    (toString cfg.port)
    "--json"
  ]
  ++ lib.optionals (cfg.pairingAddress != null) [
    "--pairing-address"
    cfg.pairingAddress
  ]
  ++ cfg.extraArgs;
  headlessOrca = pkgs.writeShellScript "orca-headless" ''
    exec ${pkgs.xvfb-run}/bin/xvfb-run \
      --auto-servernum \
      --server-args="-screen 0 1920x1080x24 -nolisten tcp" \
      ${cfg.package}/bin/orca-ide ${lib.escapeShellArgs serveArgs}
  '';
in
{
  options.my.services.orca = {
    enable = lib.mkEnableOption "Orca IDE";

    package = lib.mkPackageOption pkgs "orca-ide" { };

    mode = lib.mkOption {
      type = lib.types.enum [
        "gui"
        "headless"
      ];
      default = "headless";
      description = "Whether Orca runs as a GUI or headless runtime server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 6768;
      description = "WebSocket port for the Orca runtime.";
    };

    pairingAddress = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Address advertised to clients for pairing.";
    };

    extraArgs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ ];
      description = "Additional arguments passed to orca serve.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.activation.orcaSettings = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      ${mergeOrcaSettings}
    '';
    home.file.".local/bin/orca" = {
      source = "${orcaCli}/bin/orca";
      force = true;
    };
    home.sessionVariables.ORCA_CLI_COMMAND = "orca-ide-cli";
    home.packages = [ cfg.package orcaCli ] ++ lib.optional (cfg.mode == "headless") pkgs.xorg-server;

    systemd.user.services.orca = lib.mkIf (cfg.mode == "headless") {
      Unit = {
        Description = "Orca headless runtime server";
        Documentation = "https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md";
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };

      Service = {
        Type = "simple";
        WorkingDirectory = config.home.homeDirectory;
        Environment = [
          "LIBGL_ALWAYS_SOFTWARE=1"
          "ORCA_CLI_COMMAND=orca-ide-cli"
        ];
        StandardOutput = "journal";
        StandardError = "journal";
        SyslogIdentifier = "orca";
        ExecStart = headlessOrca;
        Restart = "on-failure";
        RestartPreventExitStatus = 3;
        RestartSec = 5;
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
