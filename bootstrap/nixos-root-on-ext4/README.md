## Steps
> Michiru installation uses its dedicated [reproducible bootstrap procedure](../michiru/README.md); this generic workflow does not apply to that host.
For installation on VPS, use the image built by [nixos-minimal-vps.nix](../nixos-iso/nixos-minimal-vps.nix) to make sure virtio kernel modules are loaded.

### 1
Follow [steps 1 - 2 in nixos-root-on-zfs](../nixos-root-on-zfs/README.md#1).

### 2
SSH into the target host as root.

#### UEFI Boot
##### If Root and ZFS partitions are on different disks
Run `bash /nixfiles/bootstrap/nixos-root-on-ext4/install.sh <hostname> <disk_path>`

#### Else If Root and ZFS partitions are on the same disks
Run `bash /nixfiles/bootstrap/nixos-root-on-ext4/install.sh <hostname> <disk_path> <root_part_size>`

#### BIOS+GPT Boot
[Arch Wiki ref](https://wiki.archlinux.org/title/Partitioning#BIOS/GPT_layout_example)

##### If Root and ZFS partitions are on different disks
Run `BIOS_BOOT=1 bash /nixfiles/bootstrap/nixos-root-on-ext4/install.sh <hostname> <disk_path>`

#### Else If Root and ZFS partitions are on the same disks
Run `BIOS_BOOT=1 bash /nixfiles/bootstrap/nixos-root-on-ext4/install.sh <hostname> <disk_path> <root_part_size>`

### 5 Create zpool

Always create an unencrypted pool.

```
zpool create \
    -O relatime=on \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=zstd \
    -O dnodesize=auto \
    -O normalization=formD \
    -O xattr=sa \
    -O devices=off \
    -f \
    <pool_name> \
    <zfs_partition>
```

#### Untrusted Host

For the untrusted host where zfs key won't be loaded, create an unencrypted dataset to [allow placeholder datasets to be created](https://zrepl.github.io/configuration/sendrecvoptions.html#placeholders).

```
zfs create -o mountpoint=none <pool_name>/unencrypted
# zfs create -o mountpoint=none <pool_name>/unencrypted/push
# zfs create -o mountpoint=none <pool_name>/unencrypted/pull
```

#### Trusted Host
For the trusted host where zfs key will be loaded, create an encrypted pool.

```
zfs create \
    -o mountpoint=none \
    -o encryption=aes-256-gcm \
    -o keyformat=passphrase \
    -o keylocation=prompt \
    <pool_name>/encrypted
zfs set mountpoint=/pool/<pool_name> <pool_name>/encrypted
```

### 6
Follow [steps 4 and 5 in nixos-root-on-zfs](../nixos-root-on-zfs/README.md#5).
