---
name: nix-switch
description: Switch this repository's NixOS or Home Manager configuration on the current machine. Use for requests to apply, activate, or switch local Nix configuration changes in /nixfiles.
---

# Switch the local Nix configuration

Use this skill only for the `/nixfiles` repository and the machine currently being operated. Run commands from `/nixfiles` so the local working tree is used.

## Choose the switch

Use the wrapper scripts by absolute path so the procedure does not depend on shell aliases:

- Home Manager: `/home/sinkerine/local/bin/switch-nix-home.sh`
- NixOS system: `/home/sinkerine/local/bin/switch-nix-os.sh`
- Home Manager without substituting cached paths: `/home/sinkerine/local/bin/switch-nix-home.sh --option substitute false`
- NixOS without substituting cached paths: `/home/sinkerine/local/bin/switch-nix-os.sh --option substitute false`

The wrappers currently use the repository-local flake URI and include the active configuration. On `kazuki`, for example, they resolve to:

```text
home-manager switch --flake path:/nixfiles#sinkerine@kazuki
sudo nixos-rebuild switch --flake path:/nixfiles#kazuki
```

Prefer `/home/sinkerine/local/bin/switch-nix-home.sh` after changing Home Manager files under `home/` or user configuration. Prefer `/home/sinkerine/local/bin/switch-nix-os.sh` after changing NixOS files under `hosts/`, system modules, or other system-level flake inputs. If a change affects both layers, run the relevant switches separately, usually Home Manager first and NixOS second when the system switch provides a dependency required by Home Manager.

## Before switching

1. Confirm the working directory is `/nixfiles`.
2. Inspect `git status --short`; preserve unrelated user changes.
3. Review the requested files and identify whether the change targets Home Manager, NixOS, or both.
4. Do not discard, reset, stash, or overwrite existing working-tree changes.

## After switching

Report the exact switch command used and whether activation succeeded. If activation fails, preserve the error and identify whether evaluation, building, activation, permissions, or substitutes caused it. Do not claim success from a build-only result.

For a non-mutating check, use the repository's build wrappers when useful:

```bash
build-nix-home.sh
build-nix-os.sh
```

These build the active Home Manager activation package or NixOS system closure without activating it.
