{
  config,
  pkgs,
  lib,
  nixinfo,
  hostname,
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
      user.email = "git@sinkerine.net";
      core.excludesFile = "${config.xdg.configHome}/git/ignore";
    };
  };

  my.services.orca = {
    enable = builtins.elem hostname [
      "kazuki"
      "asako"
      "sachi"
    ];
    mode = lib.mkDefault (if config.my.essentials.gui.enable then "gui" else "headless");
    pairingAddress = "${hostname}.m.mado.moe";
  };
}
