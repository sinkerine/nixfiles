{
  config,
  lib,
  pkgs,
  microvmNixosModule,
  ...
}:

with lib;
let
  cfg = config.my.programs.electron-vm;
  jobRoot = "/var/tmp/electron-vm";
  slots = map (n: rec {
    inherit n;
    # Host directory shared with the guest as /job.
    jobDir = "${jobRoot}/slot-${toString n}";
    sshPort = 2200 + n;
    vncPort = 5900 + n;
    runner =
      (import "${pkgs.path}/nixos/lib/eval-config.nix" {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit pkgs;
        modules = [
          microvmNixosModule
          (import ./guest.nix { inherit jobDir sshPort vncPort; })
        ];
      }).config.microvm.declaredRunner;
  }) (range 1 cfg.slots);
  electronVm = pkgs.writeShellApplication {
    name = "electron-vm";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      git
      gnused
      jq
      openssh
      rsync
      util-linux
    ];
    text = ''
      SLOTS=${toString cfg.slots}
      # Prints "JOB_DIR RUNNER SSH_PORT VNC_PORT" for a slot.
      slot_config() {
        case $1 in
      ${concatMapStrings (slot: ''
          ${toString slot.n}) echo "${slot.jobDir} ${slot.runner}/bin/microvm-run ${toString slot.sshPort} ${toString slot.vncPort}" ;;
      '') slots}
          *) return 1 ;;
        esac
      }
      ${builtins.readFile ./electron-vm.sh}
    '';
  };
in
{
  options.my.programs.electron-vm = {
    # Needs KVM on the host.
    enable = mkEnableOption "the electron-vm microvm for testing Electron apps through CDP and cua-driver";
    slots = mkOption {
      type = types.ints.between 1 99;
      default = 3;
      description = "Number of VMs that can run at once; each running VM uses 4 vCPUs and 8 GiB of RAM.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ electronVm ];

    home.file.".pi/agent/skills/electron-vm-test/SKILL.md" = mkIf config.my.programs.pi-coding-agent.enable {
      source = ./SKILL.md;
      force = true;
    };
  };
}
