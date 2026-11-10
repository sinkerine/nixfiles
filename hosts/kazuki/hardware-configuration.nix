{ config, lib, pkgs, modulesPath, hostname, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules =
    [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "rpool/data/root";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/nix" = {
    device = "rpool/system/nix";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/nixfiles" = {
    device = "rpool/data/nixfiles";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/keys" = {
    device = "rpool/data/keys";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/home" = {
    device = "rpool/data/home";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/home/sinkerine" = {
    device = "rpool/data/home/sinkerine";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/home/sinkerine/.cache" = {
    device = "rpool/data/home/sinkerine/.cache";
    fsType = "zfs";
    options = [ "zfsutil" "X-mount.mkdir" ];
    neededForBoot = true;
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };

  fileSystems."/var/lib/docker" = {
    device = "/dev/disk/by-label/DOCKER";
    fsType = "ext4";
    options = [ "nodev" "nofail" ];
  };

  swapDevices = [ ];
  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.amd.updateMicrocode =
    lib.mkDefault config.hardware.enableRedistributableFirmware;
  services.udev.extraRules = ''
    SUBSYSTEM=="nvme", KERNEL=="nvme[0-9]*", GROUP="disk"
  '';
}
