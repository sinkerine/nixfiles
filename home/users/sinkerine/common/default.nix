{
  config,
  ...
}:

{
  home = rec {
    username = "sinkerine";
    homeDirectory = "/home/${username}";
  };

  imports = [ ../../../common/baseline.nix ];

  # One agent shared by terminals, GUI apps, and user services. Home Manager
  # exports $XDG_RUNTIME_DIR/ssh-agent while preserving forwarded SSH agents.
  services.ssh-agent.enable = true;
  systemd.user.services.ssh-agent.Service.Restart = "on-failure";

  programs.git = {
    enable = true;
    ignores = [ ".pi/" ];
    settings = {
      user.name = "sinkerine";
      user.email = "git@15cm.net";
      core.excludesFile = "${config.xdg.configHome}/git/ignore";
    };
  };


}
