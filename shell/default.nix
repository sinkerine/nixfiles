{
  pkgs,
  extraPkgs ? [ ],
}:

with pkgs;

pkgs.mkShell {
  packages = [
    git
    git-lfs
    gh
    openssh
    nix
    gnused
    gnugrep
    gawk
    coreutils
    libnotify
    claude-notify
    codex-notify
  ] ++ extraPkgs;
}
