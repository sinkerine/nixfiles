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

  home.sessionVariables.GRADLE_USER_HOME = "${config.xdg.cacheHome}/gradle";
  systemd.user.sessionVariables.GRADLE_USER_HOME = config.home.sessionVariables.GRADLE_USER_HOME;

  # One agent shared by terminals, GUI apps, and user services. Home Manager
  # exports $XDG_RUNTIME_DIR/ssh-agent while preserving forwarded SSH agents.
  services.ssh-agent.enable = true;
  systemd.user.services.ssh-agent.Service.Restart = "on-failure";
  # Services do not source the shell initialization that exports this socket.
  systemd.user.sessionVariables.SSH_AUTH_SOCK = "$XDG_RUNTIME_DIR/ssh-agent";

  programs.git = {
    enable = true;
    ignores = [
      ".pi/"
      "/.agents/skills/"
    ];
    settings = {
      user.name = "sinkerine";
      user.email = "git@15cm.net";
      core.excludesFile = "${config.xdg.configHome}/git/ignore";
    };
  };


}
