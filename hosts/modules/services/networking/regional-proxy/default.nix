{ lib, ... }:

let
  inherit (lib) mkOption types;
in
{
  imports = [
    ./relay.nix
    ./exit.nix
    ./cn-client.nix
    ./turn.nix
    ./routeros.nix
  ];

  options.my.services.regionalProxy = {
    hkRelay = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Hong Kong regional proxy relay.";
    };
    usExit = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the US residential proxy exit.";
    };
    usExitSourceIPv4 = mkOption {
      type = types.str;
      default = "192.168.88.31";
      description = "Reserved Sachi source address for traffic leaving through the residential exit.";
    };
    cnClient = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the China-side proxy client.";
    };
    turn = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the regional Matrix TURN service.";
    };
    routerOsPeer = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Michiru's WireGuard peer for RouterOS Hong Kong routing.";
    };
  };
}
