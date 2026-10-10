# Small, hardware-specific RAM installer. Uses the repository's locked 26.05 input.
{ repoRoot ? toString ../.. }:
let
  flake = builtins.getFlake ("path:" + repoRoot);
  nixpkgs = flake.inputs.proxmox-nixpkgs;
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      ({ config, lib, pkgs, modulesPath, ... }: {
        imports = [
          (modulesPath + "/installer/netboot/netboot.nix")
          (modulesPath + "/profiles/minimal.nix")
          (modulesPath + "/profiles/qemu-guest.nix")
        ];
        nixpkgs.flake.setNixPath = false;
        nixpkgs.flake.setFlakeRegistry = false;
        system.modulesTree = lib.mkForce [
          ((pkgs.makeModulesClosure {
            kernel = config.boot.kernelPackages.kernel.modules;
            firmware = pkgs.emptyDirectory;
            rootModules = config.boot.initrd.availableKernelModules ++ config.boot.initrd.kernelModules ++ config.boot.kernelModules ++ [
              "virtio_pci" "virtio_blk" "virtio_net" "virtio_console"
              "ext4" "squashfs" "overlay" "loop" "zram"
              "nf_tables" "nf_conntrack" "nf_log_syslog" "nft_ct"
              "nft_chain_nat" "nft_compat" "ip_tables" "iptable_filter"
              "ip6_tables" "ip6table_filter" "x_tables" "xt_conntrack"
              "xt_LOG" "xt_pkttype" "xt_tcpudp" "xt_multiport"
              "ipt_rpfilter" "ip6t_rpfilter" "xt_comment" "xt_limit"
              "xt_mark" "xt_addrtype" "ipt_REJECT" "ip6t_REJECT"
              "nft_log" "nft_reject_inet" "nft_limit" "nft_counter"
              "nft_fib_inet"
            ];
            allowMissing = true;
          }).overrideAttrs (old: {
            # makeModulesClosure output is used as input to the initrd closure.
            # Preserve ordering and built-in metadata required by that second pass.
            builder = pkgs.writeShellScript "shrink-modules" ''
              source ${old.builder}
              cp ${config.boot.kernelPackages.kernel.modules}/lib/modules/*/modules.{order,builtin,builtin.modinfo} "$out"/lib/modules/*/
            '';
          }))
        ];
        system.stateVersion = "26.05";
        networking.hostName = "michiru-installer";
        networking.useDHCP = false;
        networking.usePredictableInterfaceNames = false;
        networking.interfaces.eth0.ipv4 = {
          addresses = [ { address = "103.117.101.12"; prefixLength = 32; } ];
          routes = [ { address = "193.41.250.250"; prefixLength = 32; } ];
        };
        networking.defaultGateway = { address = "193.41.250.250"; interface = "eth0"; };
        networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];
        services.openssh.enable = true;
        services.openssh.settings = {
          PermitRootLogin = "prohibit-password";
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
        };
        users.users.root.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIp+lvf7SQBnU+zC/uEwG/uerIdqjDzRtC1LLFsNrvwH sinkerine@id"
        ];
        services.qemuGuest.enable = true;
        zramSwap.enable = true;
        boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
        boot.initrd.compressor = "xz";
        boot.initrd.includeDefaultModules = false;
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "ext4" ];
        boot.initrd.systemd.enable = true;
        boot.initrd.systemd.services.restore-host-keys = {
          unitConfig = {
            DefaultDependencies = false;
            RequiresMountsFor = "/sysroot /dev";
          };
          wantedBy = [ "initrd.target" ];
          requiredBy = [ "rw-etc.service" ];
          before = [ "rw-etc.service" ];
          serviceConfig.Type = "oneshot";
          script = ''
            mkdir -m 755 -p /sysroot/etc/ssh
            install -m 400 /ssh/ssh_host_* /sysroot/etc/ssh/
          '';
        };
        environment.systemPackages = with pkgs; [
          nixos-install-tools parted gptfdisk e2fsprogs dosfstools
          util-linux coreutils gnugrep gawk gnused bash jq
        ];
        nix.settings.experimental-features = [ "nix-command" "flakes" ];
        system.build.installerBundle = pkgs.runCommand "michiru-installer" {} ''
          mkdir -p $out
          ln -s ${config.system.build.netbootRamdisk}/initrd $out/initrd
          ln -s ${config.system.build.kernel}/bzImage $out/bzImage
          echo "init=${config.system.build.toplevel}/init ${toString config.boot.kernelParams}" > $out/cmdline
        '';
      })
    ];
  };
in system.config.system.build.installerBundle
