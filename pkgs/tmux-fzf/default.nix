{
  lib,
  fetchFromGitHub,
  fzf,
  gnused,
  ncurses,
  tmuxPlugins,
}:

tmuxPlugins.mkTmuxPlugin {
  pluginName = "tmux-fzf";
  rtpFilePath = "main.tmux";
  version = "unstable-2026-10-17";

  src = fetchFromGitHub {
    owner = "sainnhe";
    repo = "tmux-fzf";
    rev = "2839d6bd0e13b7c5e385e131e4c217917fa73555";
    hash = "sha256-UmeqY6qzGpyU64VcSfTIGJLw/l1MrAzWo0G/Lnqy1Ks=";
  };

  postInstall = ''
    find "$target" -type f -print0 | xargs -0 sed -i -e 's|fzf |${fzf}/bin/fzf |g'
    find "$target" -type f -print0 | xargs -0 sed -i -e 's|sed |${gnused}/bin/sed |g'
    find "$target" -type f -print0 | xargs -0 sed -i -e 's|tput |${ncurses}/bin/tput |g'
  '';

  meta = {
    homepage = "https://github.com/sainnhe/tmux-fzf";
    description = "Use fzf to manage your tmux work environment!";
    longDescription = ''
      Features:
      * Manage sessions (attach, detach*, rename, kill*).
      * Manage windows (switch, link, move, swap, rename, kill*).
      * Manage panes (switch, break, join*, swap, layout, kill*, resize).
      * Multiple selection (support for actions marked by *).
      * Search commands and append to command prompt.
      * Search key bindings and execute.
      * User menu.
      * Popup window support.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
  };
}
