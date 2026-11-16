# Kazuki temporary and development data

Source code, user files, configuration, agent recovery state, and useful test reports remain in the existing backed-up datasets. Rebuildable development files belong under `${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/<project>/<workspace-or-run>/`. The existing cache dataset already excludes this directory from zrepl snapshots and replication, including future child datasets through the recursive `.cache<` rule. No additional development dataset is required.

`rpool/tmp/system` is declared as a normal-stage `/tmp` filesystem (`neededForBoot = false`). It uses `mountpoint=legacy`, so its fstab options must not include `zfsutil`. It must not be mounted in the initrd. The existing `rpool/tmp<: false` zrepl rule excludes it and all siblings/children. Keep `/tmp` disk-backed; do not use tmpfs for the observed multi-GiB development workloads.

## Run the complete migration

After saving work, preserving any useful files from `/tmp`, and finishing active development jobs, run:

```bash
sudo bash /nixfiles/hosts/kazuki/migrate-tmp-zfs.sh
```

The script provisions and initializes the dataset without changing the live `/tmp`, selects the verified system closure for the next boot, installs a one-time post-boot continuation, and immediately reboots kazuki. After reboot, the continuation verifies the booted closure, dataset, and permissions, then removes obsolete root-dataset `/tmp` contents through a private nonrecursive bind mount. It removes its own startup unit after success. Root-owned migration records remain under `/var/lib/kazuki-tmp-migration`; inspect `sudo journalctl -u kazuki-tmp-migration.service -b` or `sudo cat /var/lib/kazuki-tmp-migration/completed` for completion. Failures preserve the startup unit and diagnostics. The continuation also appends output to `/var/lib/kazuki-tmp-migration/finish.log` so its error survives missing journal entries. The script does not activate the standalone Home Manager configuration.

The manual procedure below is an alternative, not an additional step. If the first attempt already created the datasets, use the updated script, which checks and reuses them. Do not rerun the one-time `zfs create` commands.

## First-attempt failure and correction

On November 15, 2026, the original build (`xb09z7x…`) combined a legacy dataset with `zfsutil` and marked `/tmp` as initrd-required. The installed mount helper rejects that combination even in fake-mount mode; it accepts the same legacy dataset without `zfsutil`. The host was subsequently observed booted into the previous generation (`bnbd25x…`) at 15:35 PST, with `/tmp` still on `rpool/data/root` and the migration continuation failed. No persistent journal entry for the intermediate attempted boot was available, so its exact console error was not recovered.

The corrected build mounts `/tmp` during normal system startup, without `zfsutil`. The updated script rejects fstab entries with either `zfsutil` or `x-initrd.mount` before changing boot state. The original generation must not be selected for another attempt.

## Provision the dataset without changing the live /tmp

Run on kazuki. These are one-time commands: the two datasets must not already exist. If a create fails, stop and inspect the existing dataset rather than changing its properties blindly. Do not activate the new NixOS configuration before provisioning the dataset.

```bash
sudo zfs create -o mountpoint=none rpool/tmp
sudo zfs create -o mountpoint=legacy -o atime=off rpool/tmp/system
sudo install -d -m 0700 /mnt/kazuki-tmp-stage
sudo mount -t zfs rpool/tmp/system /mnt/kazuki-tmp-stage
sudo chown root:root /mnt/kazuki-tmp-stage
sudo chmod 1777 /mnt/kazuki-tmp-stage
sudo umount /mnt/kazuki-tmp-stage
sudo rmdir /mnt/kazuki-tmp-stage
```

The dataset is initially empty. Before rebooting, copy any useful files needed across reboot out of the existing `/tmp`. Stop or finish development jobs normally. Do not copy live sockets or temporary service state into the new dataset.

## Build, select the boot configuration, and reboot

The corrected verification build completed successfully (exit code zero) as qex job `e69864c7-1f98-4432-bd2b-21568b25eb3e` on kazuki. Its system closure is `/nix/store/zqkgw450k72xx27rqz15kqlaynq6r2kd-nixos-system-kazuki-26.11.20261030.1c89083`; its fstab was checked for `rpool/tmp/system /tmp zfs X-mount.mkdir 0 0`, with neither `zfsutil` nor `x-initrd.mount`. Use that result rather than submitting a duplicate:

```bash
qex status e69864c7-1f98-4432-bd2b-21568b25eb3e --wait --timeout 30s
qex logs e69864c7-1f98-4432-bd2b-21568b25eb3e
```

A wait timeout means the same job is still queued/running. Proceed only after it reports completion with exit code zero. If the relevant configuration has changed since its successful build, read the shared queue state and submit a new build through `agent-job submit heavy -- nixos-rebuild build --flake /nixfiles#kazuki --max-jobs 4 --cores 1`, retaining its returned job ID.

The successful `nixos-rebuild build` writes `/nixfiles/result`, but another build can replace that symlink. The commands below pin and verify this run's exact closure before selecting it. They boot the already-built closure without another resource-intensive build and without changing the live `/tmp` mount:

```bash
zfs_system=/nix/store/zqkgw450k72xx27rqz15kqlaynq6r2kd-nixos-system-kazuki-26.11.20261030.1c89083
test -x "$zfs_system/bin/switch-to-configuration"
rg -F 'rpool/tmp/system' "$zfs_system/etc/fstab"
# Stop if either check above fails. Review this closure before proceeding.
sudo nix-env --profile /nix/var/nix/profiles/system --set "$zfs_system"
sudo "$zfs_system/bin/switch-to-configuration" boot
# Reboot only if bootloader installation above succeeded.
sudo reboot
```

Run the checks and installation steps individually, stopping on any failure. Use `boot`, not `switch`, for this first activation so the mount transition happens during reboot. The system build includes other existing NixOS working-tree changes; review them before selecting it. Standalone Home Manager configuration has its own activation; the shared agent instructions take effect after its normal Home Manager switch and agent reload/restart.

## Verify and inspect the old root-dataset files after reboot

```bash
findmnt -T /tmp
stat -c '%a %U:%G' /tmp
```

Expected: `rpool/tmp/system` mounted at `/tmp`, with mode/ownership `1777 root:root`. Confirm the zrepl push job excludes the temporary dataset and cache subtree. Existing root/home snapshots still reference historical temporary files until normal pruning permits their removal.

The previous root-dataset `/tmp` contents are hidden by the new mount. A **nonrecursive** bind mount exposes them without unmounting the new `/tmp`:

```bash
sudo install -d -m 0700 /mnt/kazuki-root-view
sudo mount --bind / /mnt/kazuki-root-view
findmnt -T /mnt/kazuki-root-view/tmp
sudo du -sh /mnt/kazuki-root-view/tmp
sudo ls -la /mnt/kazuki-root-view/tmp
```

Before cleanup, the `findmnt` output must identify `rpool/data/root`, not `rpool/tmp/system`. Inspect and preserve anything useful. Only after verifying that these are the obsolete pre-reboot temporary files, clear their contents while retaining the old mountpoint:

```bash
sudo find /mnt/kazuki-root-view/tmp -xdev -mindepth 1 -delete
sudo umount /mnt/kazuki-root-view
sudo rmdir /mnt/kazuki-root-view
```

Do not use a recursive bind mount, delete the active `/tmp`, or remove backup snapshots as an implicit part of this migration.

## Tool integration

Prefer per-project/per-workspace output settings (for example, `CARGO_TARGET_DIR`) and cache settings over moving source checkouts. Where a tool requires project-local generated paths, use a documented project-specific link or bind mount only after verifying that the directory contains generated data and is inactive. Give concurrent runs separate mutable state. Store final reports and reproducibility inputs outside disposable scratch. Keep credentials outside scratch. Cleanup must preserve active processes, container mounts, and valuable diagnostics.

`~/.local/share` remains the default home for durable application data. Placing disposable build files there would require another excluded dataset and would obscure their cleanup semantics. A separate development dataset can be added beneath the existing cache dataset later if independent quotas or accounting become necessary.
