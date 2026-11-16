#!/usr/bin/env bash
# One-time kazuki migration. Run with sudo after saving work: this reboots.
set -Eeuo pipefail
export PATH=/run/current-system/sw/bin:/run/wrappers/bin

system=/nix/store/zqkgw450k72xx27rqz15kqlaynq6r2kd-nixos-system-kazuki-26.11.20261030.1c89083
state=/var/lib/kazuki-tmp-migration
unit=kazuki-tmp-migration.service
# NixOS's /etc/systemd/system is read-only. system.control is a persistent,
# writable unit search path (verified with systemd-analyze unit-paths).
unit_dir=/etc/systemd/system.control
unit_file=$unit_dir/$unit
wants=$unit_dir/multi-user.target.wants/$unit
dataset=rpool/tmp/system
stage=$state/stage
view=$state/root-view
stage_mounted=0
view_mounted=0

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail "Run this script with sudo."
[[ $(hostname -s) == kazuki ]] || fail "This script is only for kazuki."

# All destructive cleanup is confined to this private, nonrecursive root view.
cleanup_mounts() {
  if [[ $view_mounted == 1 ]]; then umount "$view" || true; fi
  if [[ $stage_mounted == 1 ]]; then umount "$stage" || true; fi
}
trap cleanup_mounts EXIT

verify_tmp() {
  [[ $(findmnt -rn -o SOURCE -T /tmp) == "$dataset" ]] || fail "/tmp is not mounted from $dataset."
  [[ $(stat -c '%a %u:%g' /tmp) == '1777 0:0' ]] || fail "/tmp must be mode 1777 and owned by root:root."
}

finish() {
  [[ -f $state/boot-id ]] || fail "No migration record found."
  exec 9> "$state/lock"
  flock -n 9 || fail "Another migration invocation is running."
  [[ $(< /proc/sys/kernel/random/boot_id) != "$(< "$state/boot-id")" ]] || fail "Reboot before finishing the migration."
  [[ $(readlink -f /run/booted-system) == "$system" ]] || fail "The machine did not boot the prepared system. Old /tmp files were preserved."
  verify_tmp
  [[ ! -e $state/completed ]] || { printf 'Migration already completed.\n'; return; }

  install -d -m 0700 "$view"
  mountpoint -q "$view" && fail "The root-view directory is already mounted."
  mount --bind / "$view"
  view_mounted=1
  mount --make-private "$view"
  [[ -d $view/tmp && ! -L $view/tmp ]] || fail "The old /tmp is not an ordinary directory."
  [[ $(findmnt -rn -o SOURCE -T "$view/tmp") == rpool/data/root ]] || fail "Refusing cleanup: root view does not expose rpool/data/root."
  # Refuse unexpected submounts, including any on the old /tmp itself.
  while IFS= read -r target; do
    case "$target" in
      "$view/tmp"|"$view/tmp/"*) fail "Unexpected mount under old /tmp: $target" ;;
    esac
  done < <(findmnt -rn -o TARGET)

  printf 'Removing obsolete pre-reboot files from the root dataset:\n'
  du -sh "$view/tmp"
  find "$view/tmp" -xdev -mindepth 1 -delete
  umount "$view"
  view_mounted=0
  rmdir "$view"
  verify_tmp
  date --iso-8601=seconds > "$state/completed"
  rm -- "$wants" "$unit_file"
  systemctl daemon-reload
  printf 'Migration complete. /tmp is on %s; old root-dataset files are cleared.\n' "$dataset"
  printf 'Historical snapshots are unchanged.\n'
}

if [[ ${1:-} == --finish ]]; then
  finish
  exit 0
fi
[[ $# == 0 ]] || fail "Usage: sudo bash $0"

if [[ -e $state/completed ]]; then
  verify_tmp
  printf 'Migration already completed: %s\n' "$(< "$state/completed")"
  exit 0
fi

[[ -x $system/bin/switch-to-configuration ]] || fail "The verified system closure is unavailable."
# Reject the original broken generation before changing any datasets or boot state.
awk '
  $1 == "rpool/tmp/system" && $2 == "/tmp" && $3 == "zfs" {
    found++
    count=split($4, options, ",")
    for (i=1; i<=count; i++)
      if (options[i] == "zfsutil" || options[i] == "x-initrd.mount") bad=1
  }
  END { exit !(found == 1 && !bad) }
' "$system/etc/fstab" || fail "The system must declare a normal-stage legacy /tmp mount without zfsutil or x-initrd.mount."
[[ $(findmnt -rn -o SOURCE -T /tmp) == rpool/data/root ]] || fail "Unexpected current /tmp filesystem; inspect it before proceeding."
[[ $(zfs get -H -o value mountpoint rpool/data/root) == / ]] || fail "Unexpected root dataset mountpoint."

install -d -m 0700 "$state"
# Serialize invocations without depending on /tmp.
exec 9> "$state/lock"
flock -n 9 || fail "Another migration invocation is running."

if ! zfs list -H -o name rpool/tmp >/dev/null 2>&1; then
  zfs create -o mountpoint=none rpool/tmp
fi
[[ $(zfs get -H -o value mountpoint rpool/tmp) == none ]] || fail "Existing rpool/tmp has an unexpected mountpoint."
if ! zfs list -H -o name "$dataset" >/dev/null 2>&1; then
  zfs create -o mountpoint=legacy -o atime=off "$dataset"
fi
[[ $(zfs get -H -o value mountpoint "$dataset") == legacy ]] || fail "Existing $dataset must have mountpoint=legacy."
[[ $(zfs get -H -o value mounted "$dataset") == no ]] || fail "The temporary dataset is already mounted."
[[ $(zfs get -H -o value atime "$dataset") == off ]] || fail "Existing $dataset must have atime=off."

install -d -m 0700 "$stage"
mountpoint -q "$stage" && fail "The staging directory is already mounted."
# Check the actual dataset's mount semantics, then initialize it away from /tmp.
mount.zfs -f -n "$dataset" "$stage"
mount -t zfs "$dataset" "$stage"
stage_mounted=1
[[ -z $(find "$stage" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail "The temporary dataset is not empty; preserve or inspect its contents first."
chown root:root "$stage"
chmod 1777 "$stage"
umount "$stage"
stage_mounted=0
rmdir "$stage"

# Persist the continuation outside /tmp and outside the new dataset.
self=$(readlink -f "${BASH_SOURCE[0]}")
if [[ $self != "$state/migrate.sh" ]]; then
  install -m 0700 "$self" "$state/migrate.sh"
fi
cp /proc/sys/kernel/random/boot_id "$state/boot-id"
install -d -m 0755 "$unit_dir" "$unit_dir/multi-user.target.wants"
cat > "$unit_file" <<'UNIT'
[Unit]
Description=Finish kazuki /tmp ZFS migration after reboot
After=local-fs.target
RequiresMountsFor=/tmp /var/lib/kazuki-tmp-migration
ConditionPathExists=/var/lib/kazuki-tmp-migration/boot-id
ConditionPathExists=!/var/lib/kazuki-tmp-migration/completed

[Service]
Type=oneshot
PrivateMounts=yes
ExecStart=/run/current-system/sw/bin/bash /var/lib/kazuki-tmp-migration/migrate.sh --finish
StandardOutput=append:/var/lib/kazuki-tmp-migration/finish.log
StandardError=inherit
TimeoutStartSec=infinity

[Install]
WantedBy=multi-user.target
UNIT
ln -sfn -- "../$unit" "$wants"
systemctl daemon-reload

nix-env --profile /nix/var/nix/profiles/system --set "$system"
"$system/bin/switch-to-configuration" boot
printf '\nPrepared the new /tmp dataset and boot configuration. Rebooting now.\n'
printf 'After reboot: journalctl -u %s -b\n' "$unit"
systemctl reboot
