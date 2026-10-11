{ pkgs }:

import ./default.nix {
  inherit pkgs;
  extraPkgs = with pkgs; [
    tmux
    fzf
  ];
}
