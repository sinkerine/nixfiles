{ config, lib }:
let
  amane = config.networking.hostName == "amane";
  targets = builtins.fromJSON (builtins.readFile ./reality-sni-targets.json);
in lib.mapAttrsToList (name: target: {
  type = "vless";
  tag = "reality-${name}";
  listen = "127.0.0.1";
  listen_port = target.listen_port;
  users = [
    { name = "primary"; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; }
    { name = "makina"; uuid = config.sops.placeholder.makinaXrayClientId; flow = "xtls-rprx-vision"; }
  ] ++ lib.optional amane {
    name = "kazuki"; uuid = config.sops.placeholder.kazukiXrayClientId; flow = "xtls-rprx-vision";
  };
  tls = {
    enabled = true;
    server_name = target.domain;
    reality = {
      enabled = true;
      handshake = { server = target.domain; server_port = 443; };
      private_key = config.sops.placeholder.xrayPrivateKey;
      short_id = if amane then "8c614ced" else "27323628";
    };
  };
}) targets
