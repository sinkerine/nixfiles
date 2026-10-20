{
  config,
  lib,
  pkgs,
  microvmNixosModule,
  ...
}:

with lib;
let
  cfg = config.my.programs.vm-test;
  jobRoot = "/var/tmp/vm-test";
  slots = map (n: rec {
    inherit n;
    # Host directory shared with the guest as /job.
    jobDir = "${jobRoot}/slot-${toString n}";
    sshPort = 2200 + n;
    vncPort = 5900 + n;
    guest =
      (import "${pkgs.path}/nixos/lib/eval-config.nix" {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit pkgs;
        modules = [
          microvmNixosModule
          (import ./guest.nix { inherit jobDir sshPort vncPort; })
        ];
      }).config.microvm;
    runner = guest.declaredRunner;
    share = head (filter (s: s.tag == "job") guest.shares);
    # Runs in the slot state dir: serves the job share over virtiofs as the
    # calling user, then boots the VM. virtiofsd exits once qemu disconnects.
    # Unprivileged, virtiofsd can only act as the calling user: its user
    # namespace maps that user to root, and every guest uid and gid is
    # squashed onto it. Host files show up as the guest's tester:users.
    launcher = pkgs.writeShellScript "vm-test-launch-${toString n}" ''
      rm -f ${share.socket}
      ${pkgs.virtiofsd}/bin/virtiofsd \
        --socket-path=${share.socket} \
        --shared-dir=${share.source} \
        --cache=${share.cache} \
        --uid-map=:0:"$(id -u)":1: \
        --gid-map=:0:"$(id -g)":1: \
        --translate-uid=squash-guest:0:0:4294967295 \
        --translate-gid=squash-guest:0:0:4294967295 \
        --translate-uid=host:0:1000:1 \
        --translate-gid=host:0:100:1 \
        --inode-file-handles=never \
        --rlimit-nofile=0 \
        --log-level=warn &
      virtiofsd=$!
      trap 'kill $virtiofsd 2>/dev/null' EXIT
      for _ in $(seq 100); do
        [ -S ${share.socket} ] && break
        kill -0 $virtiofsd 2>/dev/null || exit 1
        sleep 0.1
      done
      ${runner}/bin/microvm-run
    '';
  }) (range 1 cfg.slots);
  vmTest = pkgs.writeShellApplication {
    name = "vm-test";
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
      # Prints "JOB_DIR LAUNCHER RUNNER SSH_PORT VNC_PORT" for a slot.
      slot_config() {
        case $1 in
      ${concatMapStrings (slot: ''
          ${toString slot.n}) echo "${slot.jobDir} ${slot.launcher} ${slot.runner}/bin/microvm-run ${toString slot.sshPort} ${toString slot.vncPort}" ;;
      '') slots}
          *) return 1 ;;
        esac
      }
      ${builtins.readFile ./vm-test.sh}
    '';
  };
in
{
  options.my.programs.vm-test = {
    # Needs KVM on the host.
    enable = mkEnableOption "an ephemeral microvm for app testing, with Electron CDP and cua-driver support";
    slots = mkOption {
      type = types.ints.between 1 99;
      default = 3;
      description = "Number of VMs that can run at once; each running VM uses 4 vCPUs and 8 GiB of RAM.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ vmTest ];

    home.file.".pi/agent/skills/vm-test/SKILL.md" = mkIf config.my.programs.pi-coding-agent.enable {
      source = ./SKILL.md;
      force = true;
    };
  };
}
