{ pkgs, config, lib, nixinfo, hostname, ... }:

with lib;
let cfg = config.my.programs.hmSwitch;
in {
  options.my.programs.hmSwitch = {
    enable = mkEnableOption "hmSwitch";
    useImpure = mkEnableOption "impure";
  };

  config = mkIf cfg.enable {
    home.file."local/bin/switch-nix-home.sh".source =
      let homeFlakeUri = with nixinfo; "path:${projectRoot}#${configName}";
      in pkgs.writeShellScript "switch-nix-home.sh" ''
        # A Paseo-hosted switch must survive restarting its parent daemon.
        exec ${pkgs.systemd}/bin/systemd-run --user --quiet --wait --pipe --collect \
          --property=Type=exec --working-directory="$PWD" \
          --setenv=PATH="$PATH" \
          --setenv=SSH_AUTH_SOCK="''${SSH_AUTH_SOCK-}" \
          --setenv=NIX_SSHOPTS="''${NIX_SSHOPTS-}" \
          home-manager switch "$@" ${
            optionalString cfg.useImpure "--impure "
          }--flake ${homeFlakeUri}
      '';
    home.file."local/bin/switch-nix-os.sh".source =
      let osFlakeUri = with nixinfo; "path:${projectRoot}#${hostname}";
      in pkgs.writeShellScript "switch-nix-os.sh" ''
        ${if hostname == "kazuki" then ''
          # Match the existing passwordless sudo rule exactly.
          sudo -n /run/current-system/sw/bin/nixos-rebuild switch "$@" --flake ${nixinfo.projectRoot}#${hostname}
        '' else ''
          sudo nixos-rebuild switch "$@" --flake ${osFlakeUri}
        ''}
      '';
    home.file."local/bin/build-nix-home.sh".source = let
      homeTopLevelFlakeUri = with nixinfo;
        "path:${projectRoot}#homeConfigurations.${configName}.activationPackage";
    in pkgs.writeShellScript "build-nix-home.sh" ''
      nix build ${
        optionalString cfg.useImpure "--impure "
      }--no-link --print-out-paths "$@" ${homeTopLevelFlakeUri}
    '';
    home.file."local/bin/build-nix-os.sh".source = let
      osTopLevelFlakeUri = with nixinfo;
        "path:${projectRoot}#nixosConfigurations.${hostname}.config.system.build.toplevel";
    in pkgs.writeShellScript "build-nix-os.sh" ''
      nix build --no-link --print-out-paths "$@" ${osTopLevelFlakeUri}
    '';
  };
}
