{
  config,
  lib,
  pkgs,
  ...
}:

with lib;
let
  cfg = config.my.services.cua-driver;
in
{
  options.my.services.cua-driver = {
    enable = mkEnableOption "CUA Driver daemon";

    permissionMode = mkOption {
      type = types.enum [
        "standard"
        "bounded"
        "unrestricted"
      ];
      default = "standard";
      description = "Agent authorization mode passed to `cua-driver serve --permission-mode`.";
    };

    enableWayland = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the native Wayland backend (`CUA_DRIVER_RS_ENABLE_WAYLAND=1`).";
    };

    disableOverlay = mkOption {
      type = types.bool;
      default = true;
      description = "Disable the agent cursor overlay (`--no-overlay`).";
    };

    disableTelemetry = mkOption {
      type = types.bool;
      default = true;
      description = "Disable CUA Driver product telemetry before starting the daemon.";
    };
  };

  config = mkIf cfg.enable {
    home.sessionVariables = mkIf cfg.enableWayland {
      CUA_DRIVER_RS_ENABLE_WAYLAND = "1";
    };

    systemd.user.services.cua-driver = {
      Unit = {
        Description = "CUA Driver automation daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Environment = optional cfg.enableWayland "CUA_DRIVER_RS_ENABLE_WAYLAND=1";
        ExecStartPre = optional cfg.disableTelemetry "${pkgs.cua-driver}/bin/cua-driver telemetry disable";
        ExecStart = concatStringsSep " " (
          [
            "${pkgs.cua-driver}/bin/cua-driver"
            "serve"
            "--permission-mode"
            cfg.permissionMode
          ]
          ++ optional cfg.disableOverlay "--no-overlay"
        );
        Restart = "on-failure";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
