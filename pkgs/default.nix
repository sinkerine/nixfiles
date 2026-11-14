{ pkgs ? null, ... }:

with pkgs; {
  notify-lib = callPackage ./notify-lib { };
  ergodox-layout = callPackage ./ergodox-layout { };
  clipper = callPackage ./clipper { };
  codex-trusted = callPackage ./codex-trusted { };
  codex-notify = callPackage ./codex-notify { };
  codex-auth = callPackage ./codex-auth { };
  i3-quickterm = callPackage ./i3-quickterm { };
  AriaNg = callPackage ./AriaNg { };
  sarasa-gothic-nerdfont = (callPackage ./sarasa-gothic-nerdfont { });
  iosevka-nerdfont = (callPackage ./iosevka-nerdfont { });
  khinsider = (callPackage ./khinsider { });
  feishin-appimage = (callPackage ./feishin-appimage { });
  lsp-ai = (callPackage ./lsp-ai { });
  tmux-fzf = (callPackage ./tmux-fzf { });
  webos-dev-manager = (callPackage ./webos-dev-manager { });
  xurl = (callPackage ./xurl { });
  strata = callPackage ./strata { };
  pi-coding-agent = callPackage ./pi-coding-agent { };
  paseo-session-recovery = callPackage ./paseo/session-recovery.nix { };
  better-paseo = callPackage ./paseo/better-paseo.nix { };
  pi-ask-user = callPackage ./pi-ask-user { };
  pi-footer = callPackage ./pi-footer { };
  pi-ast-grep = callPackage ./pi-ast-grep { };
  pi-collapse-tools = callPackage ./pi-collapse-tools { };
  pi-goal = callPackage ./pi-goal { };
  pi-goal-x = callPackage ./pi-goal-x { };
  pi-hindsight = callPackage ./pi-hindsight { };
  workspace-dispatch = callPackage ./e2e-dispatch { };
  e2e-dispatch = pkgs.workspace-dispatch;
  pi-web-access = callPackage ./pi-web-access { };
  pi-subagents = callPackage ./pi-subagents { };
  pi-btw = callPackage ./pi-btw { };
}
