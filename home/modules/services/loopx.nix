{ config, lib, pkgs, ... }:
let
  cfg = config.my.services.loopx;
in {
  options.my.services.loopx = {
    enable = lib.mkEnableOption "LoopX WebUI and native Codex executor";
    domain = lib.mkOption { type = lib.types.str; };
    port = lib.mkOption { type = lib.types.port; default = 8767; };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [ pkgs.loopx ];
    systemd.user.services.loopx = {
      Unit = {
        Description = "LoopX WebUI and native Codex app-server executor";
        After = [ "network-online.target" ];
      };
      Service = {
        ExecStart = "${lib.getExe pkgs.loopx} chat --host 127.0.0.1 --port ${toString cfg.port} --global-registry --no-open --codex-bin ${lib.getExe pkgs.codex}";
        WorkingDirectory = config.home.homeDirectory;
        Environment = [
          "LOOPX_WEB_ORIGIN=https://${cfg.domain}"
          "LOOPX_MANAGER_MODEL=${config.programs.codex.settings.model}"
          "PATH=${lib.makeBinPath [ pkgs.codex pkgs.nodejs_24 pkgs.git pkgs.openssh pkgs.ripgrep pkgs.coreutils pkgs.bash ]}:${config.home.profileDirectory}/bin:/run/current-system/sw/bin"
        ];
        Restart = "on-failure";
        RestartSec = 5;
        KillMode = "control-group";
        TimeoutStopSec = 30;
        UMask = "0077";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
