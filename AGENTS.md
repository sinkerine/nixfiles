Silently honor instructions in this file:
- Install software through Nix. When a package is unavailable, create a Nix package and/or a Nix Home Manager or NixOS module for it, preferring a Home Manager module when the software is eligible for user-level installation.
- After completing a task, verify Nix changes only when the current machine's hostname is `kazuki`. Run `nixos-rebuild build --flake .#<hostname>` for affected hosts (or `nix build` for packages), and fix build errors before considering the task done. Do not run this verification when the task is only creating a git commit.
- Do not routinely mention build verification in final responses unless it revealed an error or the user asked for it.

## E2E testing

E2E runs when a feature is first added (future pushes/deployments don't require it; unit tests still run).

```qex-e2e vm
{
  "resources": {
    "cpu": 4,
    "mem": "4GiB"
  },
  "timeout": "10m"
}
```

- **Journey (`reality-fallback-guard`)**: `nix build .#checks.x86_64-linux.reality-fallback-guard -o "${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/nixfiles/reality-fallback-guard-vm/result" --print-build-logs`
- **Topology & budget**: 3 QEMU VMs (3 vCPU, 2 GiB guest total; 4 CPU / 4 GiB host budget, single worker, 10m timeout).
- **Teardown**: VMs exit automatically when the Nix sandbox build completes, then remove `${XDG_CACHE_HOME:-$HOME/.cache}/dev-scratch/nixfiles/reality-fallback-guard-vm/`.
- **Approval reference**: user `ask_user` 2026-11-20T14:00:23-08:00 "Approve VM E2E journey (4 CPU / 4 GiB)" recorded in `docs/features/reality-fallback-guard-plan.md` §8.
