Silently honor instructions in this file:
- Install software through Nix. When a package is unavailable, create a Nix package and/or a Nix Home Manager or NixOS module for it, preferring a Home Manager module when the software is eligible for user-level installation.
- After completing a task, verify Nix changes only when the current machine's hostname is `kazuki`. Run `nixos-rebuild build --flake .#<hostname>` for affected hosts (or `nix build` for packages), and fix build errors before considering the task done. Do not run this verification when the task is only creating a git commit.
- Do not routinely mention build verification in final responses unless it revealed an error or the user asked for it.
