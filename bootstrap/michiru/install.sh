#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
target=root@103.117.101.12
identity=${MICHIRU_IDENTITY:-/home/sinkerine/.ssh/id_ed25519}
host_build=path:$repo_root#nixosConfigurations.michiru.config.system.build
# nixos-anywhere 1.13.0, immutable revision.
anywhere=github:nix-community/nixos-anywhere/bad98b0685cf47eaeadcaf6787da8b51cf025693
expected_host_fingerprint=${MICHIRU_HOST_FINGERPRINT:-SHA256:2AgXry3qFPmsf1cWDzsbhDyQ7M2p8X08YiP5Qe2gfs0}

usage() {
  echo "Usage: $0 {build|preflight|grub|installer-check|install|inspect|reboot|verify}" >&2
}

if [[ $# != 1 ]] || [[ ! $1 =~ ^(build|preflight|grub|installer-check|install|inspect|reboot|verify)$ ]]; then
  usage
  exit 2
fi
phase=$1
umask 077
log_dir=${MICHIRU_STATE_DIR:-/home/sinkerine/michiru-install-logs}
mkdir -p "$log_dir"
log_dir=$(cd -- "$log_dir" && pwd)
build_dir=$log_dir/build
exec 9>"$log_dir/install.lock"
flock -n 9 || { echo "Another Michiru phase is running" >&2; exit 1; }
exec > >(tee -a "$log_dir/$(date -u +%Y%m%dT%H%M%SZ)-$phase.log") 2>&1

fail() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "ERROR: phase $phase stopped at line $LINENO; inspect log before retrying." >&2' ERR

if [[ $phase == build ]]; then
  mkdir -p "$build_dir"
  rm -f "$build_dir/complete"
  nix build --impure --file "$repo_root/bootstrap/michiru/installer.nix" \
    --argstr repoRoot "$repo_root" --out-link "$build_dir/installer"
  nix build "$host_build.toplevel" --out-link "$build_dir/system"
  nix build "$host_build.diskoScriptNoDeps" --out-link "$build_dir/disko"
  nix build "$anywhere" --out-link "$build_dir/anywhere"
  cp "$repo_root/flake.lock" "$build_dir/flake.lock"
  for artifact in installer system disko anywhere; do
    readlink -f "$build_dir/$artifact"
  done | tee "$build_dir/store-paths.txt"
  touch "$build_dir/complete"
  exit
fi

if [[ ! -r $identity ]]; then
  echo "SSH identity not readable: $identity" >&2
  exit 1
fi
command -v nix >/dev/null || { echo "nix is required" >&2; exit 1; }

# A provider reset replaced the Debian host key. Verify the observed key before
# using an isolated known-hosts file. Host keys are preserved across installation.
known_hosts=$(mktemp)
trap 'rm -f "$known_hosts"' EXIT
ssh-keyscan -T 10 -t ed25519 103.117.101.12 > "$known_hosts" 2>/dev/null || fail "No SSH host key received; wait for boot or inspect provider console."
observed_fingerprint=$(ssh-keygen -lf "$known_hosts" -E sha256 | awk 'NR == 1 { print $2 }')
if [[ $observed_fingerprint != "$expected_host_fingerprint" ]]; then
  echo "Unexpected Michiru SSH host key: ${observed_fingerprint:-none}" >&2
  exit 1
fi

ssh_args=(-i "$identity" -o BatchMode=yes -o ConnectTimeout=10 -o UserKnownHostsFile="$known_hosts" -o StrictHostKeyChecking=yes)
if [[ $phase == verify ]]; then
  ssh "${ssh_args[@]}" "$target" 'set -eu
    test "$(hostname)" = michiru
    test -e /etc/NIXOS
    test "$(findmnt -no FSTYPE /)" = ext4
    test "$(blkid -s LABEL -o value /dev/vda2)" = ROOT
    ip -4 addr show eth0 | grep -q "103.117.101.12/32"
    ip -4 route show default | grep -q "via 193.41.250.250"
    systemctl is-active sshd qemu-guest-agent firewall
    test -z "$(systemctl --failed --no-legend)"
    swapon --show=NAME --noheadings | grep -q /dev/zram
    hostname
    cat /etc/os-release
    findmnt /
    ip -4 route
    free -m
    swapon --show
    systemctl --failed --no-pager'
  exit
fi

if [[ $phase == preflight || $phase == grub ]]; then
  ssh "${ssh_args[@]}" "$target" 'set -eu
    test "$(uname -m)" = x86_64
    . /etc/os-release
    test "$ID" = debian
    test "$VERSION_ID" = 13
    test ! -d /sys/firmware/efi
    test "$(findmnt -no SOURCE /)" = /dev/vda1
    test "$(lsblk -dnbo SIZE /dev/vda)" = 21474836480
    command -v cloud-init >/dev/null
    command -v python3 >/dev/null
    cloud-init status --wait >/dev/null || true
    cloud-init status --format json | python3 -c "import json,sys; s=json.load(sys.stdin); assert s[\"status\"] == \"done\" and not s.get(\"errors\")"
    for cmd in cpio gzip find tar python3 grub-reboot grub-script-check grub-editenv update-grub; do
      command -v "$cmd" >/dev/null
    done
    ip -4 addr show eth0 | grep -q "103.117.101.12/32"
    ip -4 route show default | grep -q "via 193.41.250.250"
    free -m
    ip -4 route
    echo "Debian boot preflight passed"'
fi
[[ $phase != preflight ]] || exit 0

if [[ $phase == grub ]]; then
  [[ -f $build_dir/complete ]] || fail "Run build phase successfully first"
  for artifact in installer system disko anywhere; do
    [[ -e $build_dir/$artifact ]] || fail "Run build phase first: missing $build_dir/$artifact"
  done
  bundle=$(readlink -f "$build_dir/installer")
  ssh "${ssh_args[@]}" "$target" 'tar -czf - /etc/ssh/ssh_host_* /etc/default/grub /boot/grub/grub.cfg' \
    > "$log_dir/debian-backup-$(date -u +%Y%m%dT%H%M%SZ).tar.gz"
  ssh "${ssh_args[@]}" "$target" 'mkdir -p /root/nixos-installer; chmod 700 /root/nixos-installer'
  scp "${ssh_args[@]}" "$bundle/bzImage" "$bundle/initrd" "$bundle/cmdline" "$target:/root/nixos-installer/"
  ssh "${ssh_args[@]}" "$target" bash -s <<'REMOTE'
set -euo pipefail
cd /root/nixos-installer
chmod 600 initrd
rm -rf metadata
mkdir -p metadata/ssh
cp /etc/ssh/ssh_host_* metadata/ssh/
(cd metadata; find ssh | cpio -o -H newc | gzip) >> initrd
cmdline=$(cat cmdline)
test -n "$cmdline"
uuid=$(findmnt -no UUID /)
cat > /etc/grub.d/42_nixos_installer <<EOF
#!/bin/sh
exec tail -n +3 \$0
menuentry 'NixOS 26.05 installer (once)' --id nixos-installer-once {
  insmod ext2
  search --no-floppy --fs-uuid --set=root $uuid
  linux /root/nixos-installer/bzImage $cmdline
  initrd /root/nixos-installer/initrd
}
EOF
chmod +x /etc/grub.d/42_nixos_installer
update-grub
grub-script-check /boot/grub/grub.cfg
grub-reboot nixos-installer-once
grub-editenv /boot/grub/grubenv list
systemctl reboot
REMOTE
  exit
fi

if [[ $phase == installer-check || $phase == install || $phase == inspect || $phase == reboot ]]; then
  ssh "${ssh_args[@]}" "$target" 'set -eu
    test -e /etc/NIXOS
    test "$(hostname)" = michiru-installer
    test "$(findmnt -no FSTYPE /)" = tmpfs
    test "$(lsblk -dnbo SIZE /dev/vda)" = 21474836480
    ip -4 addr show | grep -q "103.117.101.12/32"
    ip -4 route show default | grep -q "via 193.41.250.250"
    command -v nix >/dev/null
    systemctl is-active sshd qemu-guest-agent firewall
    test -z "$(systemctl --failed --no-legend)"
    swapon --show=NAME --noheadings | grep -q /dev/zram
    free -m
    ip -4 route'
fi
if [[ $phase == inspect || $phase == reboot ]]; then
  ssh "${ssh_args[@]}" "$target" 'set -eu
    test "$(findmnt -no FSTYPE /mnt)" = ext4
    test -s /mnt/boot/grub/grub.cfg
    chroot /mnt /nix/var/nix/profiles/system/sw/bin/test -e /nix/var/nix/profiles/system/init
    test -s /mnt/etc/ssh/ssh_host_ed25519_key
    test -s /mnt/boot/grub/i386-pc/core.img
    grep -q "console=ttyS0,115200n8" /mnt/boot/grub/grub.cfg
    grep -q "terminal_output console serial" /mnt/boot/grub/grub.cfg
    chroot /mnt /nix/var/nix/profiles/system/sw/bin/test -f /etc/systemd/system/qemu-guest-agent.service
    chroot /mnt /nix/var/nix/profiles/system/sw/bin/grep -q AAAAC3NzaC1lZDI1NTE5AAAAIIp+lvf7SQBnU+zC/uEwG/uerIdqjDzRtC1LLFsNrvwH /etc/ssh/authorized_keys.d/root
    cmp /etc/ssh/ssh_host_ed25519_key.pub /mnt/etc/ssh/ssh_host_ed25519_key.pub
    findmnt /mnt
    sgdisk -p /dev/vda'
fi
if [[ $phase == inspect || $phase == installer-check ]]; then
  exit
fi

extra_args=()
if [[ $phase == install ]]; then
  ssh "${ssh_args[@]}" "$target" 'set -eu
    if findmnt /mnt >/dev/null; then
      echo "/mnt already mounted; inspect previous install before retrying" >&2
      exit 1
    fi
    # This layout supports only plain ext4; reject unexpected storage stacks.
    test -z "$(lsblk -nr -o FSTYPE /dev/vda | grep -Ev "^(|ext4)$")"
    for cmd in bash jq lsblk realpath dirname wipefs dd awk grep sed blkid sgdisk partprobe udevadm mkfs.ext4 mount umount findmnt mktemp mkdir rm nixos-install; do
      command -v "$cmd" >/dev/null
    done'
  extra_args+=(--no-disko-deps)
fi

case $phase in
  install)
    phases=disko,install
    ;;
  reboot)
    phases=reboot
    ;;
esac

[[ -f $build_dir/complete ]] || fail "Run build phase successfully first"
for artifact in system disko anywhere; do
  [[ -e $build_dir/$artifact ]] || fail "Run build phase first: missing $build_dir/$artifact"
done
"$build_dir/anywhere/bin/nixos-anywhere" \
  --store-paths "$(readlink -f "$build_dir/disko")" "$(readlink -f "$build_dir/system")" \
  --target-host "$target" \
  --ssh-option "UserKnownHostsFile=$known_hosts" \
  --ssh-option StrictHostKeyChecking=yes \
  --ssh-option ConnectTimeout=10 \
  --ssh-option "IdentityFile=$identity" \
  "${extra_args[@]}" \
  --copy-host-keys \
  --build-on local \
  --phases "$phases"
