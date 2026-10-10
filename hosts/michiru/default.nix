{ config, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/services/networking/regional-proxy
    ./disk-config.nix
  ];

  system.stateVersion = "25.11";
  networking.hostName = "michiru";
  users.mutableUsers = false;
  users.users.root.hashedPasswordFile = config.sops.secrets.hashedPassword.path;
  users.users.sinkerine = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    hashedPasswordFile = config.sops.secrets.hashedPassword.path;
    openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
  };
  networking.useDHCP = false;
  networking.usePredictableInterfaceNames = false;
  networking.interfaces.eth0.ipv4 = {
    addresses = [ { address = "103.117.101.12"; prefixLength = 32; } ];
    routes = [ { address = "193.41.250.250"; prefixLength = 32; } ];
  };
  networking.defaultGateway = { address = "193.41.250.250"; interface = "eth0"; };
  networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];
  networking.firewall.enable = true;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets = {
    hashedPassword = {
      sopsFile = ./secrets.yaml;
      neededForUsers = true;
    };
  } // lib.genAttrs [ "regionalProxySocksUser" "regionalProxySocksPassword" ] (name: {
      sopsFile = ../sachi/regional-proxy-secrets.yaml;
      key = name;
      owner = if config.my.services.regionalProxy.hkRelay then "sing-box" else "root";
      group = if config.my.services.regionalProxy.hkRelay then "sing-box" else "root";
      mode = "0400";
      restartUnits = lib.optional config.my.services.regionalProxy.hkRelay "sing-box-hk-relay.service";
    })
    // lib.genAttrs [
      "regionalProxyHKDirectUUID"
      "regionalProxyUSExitUUID"
      "regionalProxyRealityPrivateKey"
      "regionalProxyRealityShortID"
      "regionalProxyTailnetSocksUser"
      "regionalProxyTailnetSocksPassword"
    ] (name: {
      sopsFile = ./relay-secrets.yaml;
      key = builtins.getAttr name {
        regionalProxyHKDirectUUID = "hkDirectUUID";
        regionalProxyUSExitUUID = "usExitUUID";
        regionalProxyRealityPrivateKey = "realityPrivateKey";
        regionalProxyRealityShortID = "realityShortId";
        regionalProxyTailnetSocksUser = "tailnetSocksUser";
        regionalProxyTailnetSocksPassword = "tailnetSocksPassword";
      };
      owner = if config.my.services.regionalProxy.hkRelay then "sing-box" else "root";
      group = if config.my.services.regionalProxy.hkRelay then "sing-box" else "root";
      mode = "0400";
      restartUnits = lib.optional config.my.services.regionalProxy.hkRelay "sing-box-hk-relay.service";
    })
    // {
      matrixTurnSharedSecret = {
        sopsFile = ./regional-proxy-turn-secrets.yaml;
        key = "matrixTurnSharedSecret";
        owner = "turnserver";
        group = "turnserver";
        mode = "0400";
      };
      cloudflareDnsApiToken = {
        sopsFile = ./regional-proxy-turn-secrets.yaml;
        key = "cloudflareDnsApiToken";
        owner = "root";
        group = "root";
        mode = "0400";
      };
    };
  systemd.tmpfiles.rules = [
    "d /etc/regional-proxy/credentials 0750 root ${if config.my.services.regionalProxy.hkRelay then "sing-box" else "root"} - -"
    "L+ /etc/regional-proxy/credentials/sachi-socks-user - - - - ${config.sops.secrets.regionalProxySocksUser.path}"
    "L+ /etc/regional-proxy/credentials/sachi-socks-password - - - - ${config.sops.secrets.regionalProxySocksPassword.path}"
    "L+ /etc/regional-proxy/credentials/hk-direct-uuid - - - - ${config.sops.secrets.regionalProxyHKDirectUUID.path}"
    "L+ /etc/regional-proxy/credentials/us-exit-uuid - - - - ${config.sops.secrets.regionalProxyUSExitUUID.path}"
    "L+ /etc/regional-proxy/credentials/reality-private-key - - - - ${config.sops.secrets.regionalProxyRealityPrivateKey.path}"
    "L+ /etc/regional-proxy/credentials/reality-short-id - - - - ${config.sops.secrets.regionalProxyRealityShortID.path}"
    "L+ /etc/regional-proxy/credentials/tailnet-socks-user - - - - ${config.sops.secrets.regionalProxyTailnetSocksUser.path}"
    "L+ /etc/regional-proxy/credentials/tailnet-socks-password - - - - ${config.sops.secrets.regionalProxyTailnetSocksPassword.path}"
  ];

  my.services.regionalProxy = {
    hkRelay = true;
    routerOsPeer = true;
    routerOsPeerPublicKey = lib.strings.trim (builtins.readFile ./routeros-public.pub);
    turn = true;
    turnOptions = {
      publicIPv4 = "103.117.101.12";
      sharedSecretFile = config.sops.secrets.matrixTurnSharedSecret.path;
      cloudflareTokenFile = config.sops.secrets.cloudflareDnsApiToken.path;
      ipv6Interface = "eth0";
      ipv6Dns.enable = true;
    };
  };

  boot.loader.grub = {
    enable = true;
    gfxmodeBios = "text";
    font = null;
    splashImage = null;
    extraConfig = ''
      serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1
      terminal_input console serial
      terminal_output console serial
    '';
  };
  boot.loader.timeout = 10;
  boot.initrd.availableKernelModules = [ "virtio_blk" "virtio_pci" ];
  boot.kernelParams = [ "console=tty0" "console=ttyS0,115200n8" ];
  zramSwap.enable = true;

  services.qemuGuest.enable = true;
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "yes";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIp+lvf7SQBnU+zC/uEwG/uerIdqjDzRtC1LLFsNrvwH sinkerine@id"
  ];
}
