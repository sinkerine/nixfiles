## Steps
> Michiru installation uses its dedicated [reproducible bootstrap procedure](../michiru/README.md); this generic workflow does not apply to that host.
### 1
Reinstall the system to make a partition for ZFS in the boot OS image.

### 2
Deploy an SSH key for the root user by `ssh-copy-id`.

### 3
SSH into the target host and run:
```
curl https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect | NIX_CHANNEL=nixos-26.05 NO_SWAP=1 bash -x
```

### 4
Follow [steps 1 - 2 in nixos-root-on-zfs](../nixos-root-on-zfs/README.md#1).

### 5
Run `bash /nixfiles/bootstrap/unverified-nixos-infect-root-on-ext4/install.sh <hostname>`

### 6
Follow [steps 5 in nixos-root-on-zfs](../nixos-root-on-zfs/README.md#5).
