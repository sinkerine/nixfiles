# Usage
> Michiru installation uses its dedicated [reproducible bootstrap procedure](../michiru/README.md); this generic workflow does not apply to that host.
NIXPKGS_ALLOW_BROKEN=1 NIX_PATH=nixpkgs=https://github.com/NixOS/nixpkgs/archive/refs/heads/nixos-26.05.tar.gz nix-shell -p nixos-generators --run "nixos-generate --format iso --configuration ./nixos-minimal.nix -o /tmp/nixos-install-image"
