{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.services.orca;
  settingsFormat = pkgs.formats.json { };
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

    settings = lib.mkOption {
      type = settingsFormat.type;
      default = { };
      description = ''
        Global Orca settings merged into each profile at startup through Orca's
        SQLite persistence. Objects merge recursively; declared scalars and
        arrays replace existing values. Unspecified settings are preserved.
        Removing a declaration leaves its last saved value in the profile.
        Restart Orca after switching to apply changes. Do not put secrets here:
        this file is stored in the world-readable Nix store.
      '';
    };

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
    xdg.configFile."orca/nix-settings.json".source =
      settingsFormat.generate "orca-nix-settings.json" cfg.settings;
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
