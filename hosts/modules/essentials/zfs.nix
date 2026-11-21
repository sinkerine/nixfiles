{ config, lib, pkgs, hostname, ... }:

with lib;
let
  cfg = config.my.essentials.zfs;
  unlock = cfg.remoteUnlock;
  pool = head (splitString "/" unlock.dataset);
  importUnit = "zfs-import-${pool}.service";
  unlockService = "${hostname}-zfs-unlock";
  unlockUnit = "${unlockService}.service";
  poolTarget = "${hostname}-pool";
in {
  options.my.essentials.zfs = {
    enable = mkEnableOption "zfs";
    enableZfsUnstable = mkEnableOption "zfs unstable";
    enableZed = mkEnableOption "zed";
    nonRootPools = mkOption {
      type = with types; listOf str;
      default = [ ];
      description = "non root pools to be imported on boot";
    };
    remoteUnlock = {
      enable = mkEnableOption "interactive ZFS unlock after SSH starts";
      dataset = mkOption {
        type = types.str;
        description = "Encryption root to unlock.";
      };
      mountPoint = mkOption {
        type = types.str;
        description = "Mount point of the encryption root.";
      };
      services = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Service names to start through the pool target after mount.";
      };
    };
    arcMaxBytes = mkOption {
      type = with types; nullOr int;
      default = null;
      description = "Maximum ZFS ARC size in bytes.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      boot.supportedFilesystems = [ "zfs" ];
      boot.zfs.forceImportAll = true;
      boot.zfs.forceImportRoot = true;
      boot.zfs.extraPools = cfg.nonRootPools;
      boot.zfs.devNodes = "/dev/disk/by-path";
      services.zfs.autoScrub.enable = true;
    }
    (mkIf unlock.enable {
      assertions = [ {
        assertion = elem pool cfg.nonRootPools;
        message = "The remote ZFS unlock dataset must belong to a configured non-root pool.";
      } ];

      # Keep the passphrase prompt out of early boot so SSH can start first.
      boot.zfs.requestEncryptionCredentials = false;
      systemd.targets.${poolTarget} = {
        description = "Unlock ${hostname}'s ZFS pool and start its services";
        requires = [ unlockUnit ];
        after = [ unlockUnit ];
      };
      systemd.services = {
        ${unlockService} = {
          description = "Unlock and mount ${unlock.dataset}";
          requires = [ importUnit ];
          after = [ "zfs-mount.service" importUnit ];
          path = [ config.boot.zfs.package pkgs.util-linux ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            set -o pipefail
            if [ "$(zfs get -H -o value keystatus ${escapeShellArg unlock.dataset})" != available ]; then
              systemd-ask-password --timeout=5min ${escapeShellArg "Enter ZFS passphrase for ${unlock.dataset}:"} \
                | zfs load-key ${escapeShellArg unlock.dataset}
            fi
            zfs mount -a
            mountpoint -q ${escapeShellArg unlock.mountPoint}
          '';
        };
      } // genAttrs unlock.services (_: {
        wantedBy = mkForce [ "${poolTarget}.target" ];
        after = [ unlockUnit ];
        unitConfig.ConditionPathIsMountPoint = unlock.mountPoint;
      });
    })
    (mkIf (cfg.arcMaxBytes != null) {
      boot.kernelParams = [ "zfs.zfs_arc_max=${toString cfg.arcMaxBytes}" ];
    })
    (mkIf cfg.enableZfsUnstable { boot.zfs.package = pkgs.zfs_unstable; })
    (mkIf cfg.enableZed {
      services.zfs.zed = {
        # this option does not work; will return error
        enableMail = false;
        settings = {
          ZED_DEBUG_LOG = "/tmp/zed.debug.log";
          ZED_EMAIL_ADDR = [ "root" ];
          ZED_EMAIL_PROG = "${pkgs.msmtp}/bin/msmtp";
          ZED_EMAIL_OPTS = "@ADDRESS@";

          ZED_NOTIFY_INTERVAL_SECS = 3600;

          ZED_USE_ENCLOSURE_LEDS = true;
          ZED_SCRUB_AFTER_RESILVER = true;
        };
      };
    })
  ]);
}
