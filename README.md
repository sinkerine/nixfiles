## Use cases
- [x] NixOS root on ZFS, for machines that run Linux desktop environment. Currently one laptop and one desktop. See [bootstrap/nixos-root-on-zfs/README.md](./bootstrap/nixos-root-on-zfs/README.md) for the bootstrap steps.
- [x] NixOS root on EXT4 + ZFS datasets under /pool, for headless machines like NAS, VPS e.t.c.
- [x] Nix Home Manager on non-NixOS Linux systems for corp machines.
- [ ] Nix Home Manager on Darwin for corp machines.

## Boundary between NixOS and Nix Home Manager
The NixOS modules and Home Manager modules are isolated as much as possible. The Home Manager is installed in standalone mode via flake. This setup allows us to rely on NixOS as less as possible to avoid breaking the Home Manager experience on non NixOS systems.

From a packages point of view, NixOS modules cover the minimum softwares that are either required for system bootstrap or shipped with most of the distros and don't require customizations. All other packages go to Home Manager modules.

From a Linux desktop environment point of view, NixOS modules control system wise and hardware wise configs. It delegates controls to Home Manager modules right after the display mananger.

## Version Control
This repo uses Git for local history, branching, and GitHub pushes.

Clone the repo with:

```bash
git clone git@github.com:sinkerine/nixfiles.git /nixfiles
cd /nixfiles
```

Daily Git commands and workflow notes live in [docs/git.md](./docs/git.md).

## References
* [Wayland software list -- Are we Wayland yet?](https://arewewaylandyet.com/)
