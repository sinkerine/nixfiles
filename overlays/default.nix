{
  nixpkgs,
  llm-agents,
  fcitx5-vinput,
  cua,
  paseo,
  ...
}:

with nixpkgs.lib;
let
  llmAgentsFor = system: llm-agents.packages.${system};
  fcitx5VinputFor = system: fcitx5-vinput.packages.${system};
  overrideElectronDesktopItemForWayland = (
    old: rec {
      desktopItems = (
        map (
          desktopItem:
          desktopItem.override (d: {
            exec = "${d.exec} --ozone-platform-hint=auto --enable-features=WaylandWindowDecorations --enable-wayland-ime";
          })
        ) old.desktopItems
      );
    }
  );
in
{
  # Adds my custom packages
  additions =
    final: _prev:
    let
      llmAgentsPkgs = llmAgentsFor final.stdenv.hostPlatform.system;
      cuaPkgs = cua.packages.${final.stdenv.hostPlatform.system};
      cuaDriver = cuaPkgs.cua-driver;
    in
    (import ../pkgs {
      pkgs = final;
    })
    // {
      cua-driver = cuaDriver;
      cua = cuaDriver.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          ln -s cua-driver "$out/bin/cua"
        '';
      });
      paseo = paseo.packages.${final.stdenv.hostPlatform.system}.paseo;
      paseo-desktop = paseo.packages.${final.stdenv.hostPlatform.system}.desktop;
      inherit (llmAgentsPkgs) codex;
      "claude-code" = llmAgentsPkgs.claude-code;
      inherit (fcitx5VinputFor final.stdenv.hostPlatform.system) fcitx5-vinput;
    };
  modifications = final: prev: rec {
      powerline = prev.powerline.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace powerline/commands/daemon.py \
            --replace-fail $'\texclusive_group = parser.add_mutually_exclusive_group()\n' "" \
            --replace-fail $'\texclusive_group.add_argument' $'\tparser.add_argument' \
            --replace-fail $'\treplace_group = exclusive_group.add_argument_group()\n' "" \
            --replace-fail $'\treplace_group.add_argument' $'\tparser.add_argument'
        '';
      });
      # pdm is blocked for now by https://github.com/NixOS/nixpkgs/pull/513116.
      feishin = prev.feishin.overrideAttrs overrideElectronDesktopItemForWayland;
      aria2-fast = prev.aria2.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./aria2-fast.patch ];
      });
      os-prober = prev.os-prober.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace common.sh --replace-fail 'if [ -z "$OS_PROBER_DISABLE_DEBUG" ]; then' 'if [ -n "$OS_PROBER_DEBUG" ]; then'
        '';
      });
  };
}
