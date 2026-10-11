{ config, pkgs, lib, state, nixinfo, hostname, ... }:

with lib;
{
  programs.home-manager.enable = true;
  news.display = "silent";

  home.packages = (with pkgs; [
    eza
    fd
    htop
    lsof
    bind
    hunspell
    hunspellDicts.en_US-large
    parallel
    tree
    ast-grep
    cua-driver
    cua
  ]);

  my.services.nix-home-manager-gc.enable = true;
  my.programs.zsh.enable = true;
  my.programs.tmux.enable = true;
  my.programs.fontconfig.enable = true;
  my.programs.nvim.enable = true;
  my.programs.vim.enable = true;
  my.programs.herdr.enable = true;
  my.programs.fzf.enable = true;
  my.programs.set-theme.enable = true;
  my.programs.yazi = { enable = true; };
  my.programs.navi.enable = true;
  my.programs.hmSwitch.enable = true;
  my.programs.powerline.enable = true;
  my.programs.codex.enableCLIProxyAPI = true;

  programs.bottom = {
    enable = true;
    settings = {
      flags = {
        color = (if state.theme == "light" then "gruvbox-light" else "gruvbox");
      };
    };
  };
  programs.zoxide = { enable = true; };
  programs.tealdeer = {
    enable = true;
    settings = { updates = { auto_update = true; }; };
  };
  programs.ripgrep = {
    enable = true;
    arguments = [ "--smart-case" ];
  };
}
