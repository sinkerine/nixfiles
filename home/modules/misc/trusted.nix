{
  config,
  hostname,
  lib,
  ...
}:
with lib; let
  cfg = config.my.profiles.trusted;
in {
  options.my.profiles.trusted = {
    enable = mkEnableOption "trusted workstation profile";
  };

  config = mkIf cfg.enable {
    my.programs.ai-agents.enable = true;

    sops = {
      defaultSopsFile = ../../users/sinkerine/common/secrets.yaml;
      age = {
        keyFile = "/keys/age/${hostname}.txt";
        sshKeyPaths = [ ];
      };
      # https://github.com/Mic92/sops-nix/issues/167
      gnupg.sshKeyPaths = [ ];
    };

    sops.secrets.githubToken = { };
    sops.secrets.myPwd = { };
    sops.secrets.volcengineArkAPIKey = { };

    my.programs.nvim = {
      enable = true;
    };
    my.programs.gh.enable = true;
    my.programs.obsidian.enable = true;
  };
}
