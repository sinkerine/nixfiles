# Michiru NixOS install

Run from Kazuki in this checkout. Keep the tree unchanged from `build`
through `install`; build links and logs live in
`/home/sinkerine/michiru-install-logs` (override with
`MICHIRU_STATE_DIR`). The phase runner serializes invocations and saves
private logs with mode 0600.

## Prerequisites

- Nix with flakes; local x86_64 Linux builder.
- Root SSH access to `103.117.101.12` using
  `/home/sinkerine/.ssh/id_ed25519`, loaded in ssh-agent if encrypted.
- Fresh Debian 13 on BIOS, exact 20 GiB `/dev/vda`, ext4 root on
  `/dev/vda1`, one GiB RAM and one GiB swap.
- Debian cloud-init finished, network on `eth0`, IPv4
  `103.117.101.12/32` via `193.41.250.250`.
- Provider VNC/console available through first boot and install recovery.

The fixed installer and host configuration target this exact VM. Stop if
preflight reports different OS, firmware, disk size, root device or routes.
Do not adapt these constants and run against another disk.

## Establish SSH host trust

The runner pins the current Debian ED25519 key fingerprint. After a provider
reset or fresh Debian reinstall, read the fingerprint through trusted provider
console:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub -E sha256
```

Compare it with the key observed through trusted provider console, then
run the script with that fingerprint. Use the same value for each phase, or
export it once for the shell session:

```sh
MICHIRU_HOST_FINGERPRINT=SHA256:paste-verified-value ./bootstrap/michiru/install.sh preflight
```

The fingerprint applies to each phase command. Export it for the remaining
commands after a reset. The install preserves the Debian SSH host keys, so
NixOS accepts the same key. The runner uses a temporary known-hosts file and
does not alter the user's SSH trust database.

## Procedure

Build all pinned artifacts first. Preserve the checkout and state directory
until install completes:

```sh
./bootstrap/michiru/install.sh build
./bootstrap/michiru/install.sh preflight
./bootstrap/michiru/install.sh grub
```

GRUB phase copies the small NixOS 26.05 netboot installer to Debian root,
embeds Debian SSH host keys in its initrd, generates and validates a GRUB
entry, selects that entry once, and reboots. Normal GRUB selection remains
Debian if the one-time entry does not boot.

Wait for installer SSH, then confirm it before any disk work:

```sh
./bootstrap/michiru/install.sh installer-check
```

Installer check requires tmpfs root, captured IPv4 route, SSH, firewall,
guest agent, zram and zero failed units. It reports available RAM. If check
fails, use VNC to inspect; reboot once to return to Debian. Do not run
`install` without successful check.

Installation erases `/dev/vda`. Disko creates GPT, 1 MiB BIOS boot partition
and ext4 root labelled `ROOT`. Reboot remains a separate, gated phase:

```sh
./bootstrap/michiru/install.sh install
./bootstrap/michiru/install.sh inspect
./bootstrap/michiru/install.sh reboot
./bootstrap/michiru/install.sh verify
```

Inspect must pass before reboot. It checks mounted ext4, BIOS GRUB core,
serial settings, installed system closure, authorized key and preserved SSH
host key. Verify checks hostname, NixOS identity, ext4 label, public address,
gateway, firewall, SSH, guest agent, zram and failed units.

Each phase is safe to rerun only when its preconditions hold. Install refuses
an already-mounted `/mnt`; after a failed install, inspect remote state and
logs before any recovery or retry. Never repeat Disko formatting blindly.

## RAM and image

The official NixOS 26.05 installer panicked while unpacking its initrd on this
one GiB VM. The reproducible installer here keeps only needed kernel modules,
omits the embedded nixpkgs source, enables 482 MiB zram, and boots from a
one-time GRUB entry. Local QEMU test completed installation and BIOS disk boot
at 1024 MiB RAM. It confirmed SSH, ext4, guest agent, zram and zero failed
units.

Installer uses the repository's locked NixOS 26.05 input. Installed host
build follows the repository's locked unstable nixpkgs, currently NixOS 26.11.
nixos-anywhere is pinned to revision
`bad98b0685cf47eaeadcaf6787da8b51cf025693` (1.13.0).

## Completed install

On 2026-10-07 installation and reboot completed. SSH, host key, hostname
`michiru`, ext4 `ROOT`, fixed IPv4/gateway, firewall, guest agent, zram and
zero failed units verified. Physical RAM remains one GiB.
