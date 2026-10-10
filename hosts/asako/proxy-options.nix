{ config, lib, pkgs, ... }:

let
  stateEnvironment = {
    ASAKO_IP = "${pkgs.iproute2}/bin/ip";
    ASAKO_IPTABLES = "${pkgs.iptables}/bin/iptables";
    ASAKO_IP6TABLES = "${pkgs.iptables}/bin/ip6tables";
  };
in
with lib;

{
  options.my.asakoProxy = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install and run Asako's sing-box localhost proxy.";
    };
    defaultEnabled = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Asako's sing-box TUN routing at boot.";
    };
  };

  config = mkIf config.my.asakoProxy.enable {
    systemd.services.sing-box-proxy = {
      description = "Asako local sing-box proxy";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${config.sops.templates."sing-box-proxy.json".path}";
        Restart = "on-failure";
        User = "root";
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
      };
    };
    systemd.services.sing-box-tun = {
      description = "Asako sing-box TUN routing";
      requires = [ "sing-box-proxy.service" ];
      after = [ "network-online.target" "sing-box-proxy.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.sing-box}/bin/sing-box run -c ${config.sops.templates."sing-box-tun.json".path}";
        Restart = "on-failure";
        User = "root";
        CapabilityBoundingSet = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        AmbientCapabilities = "CAP_NET_ADMIN CAP_NET_BIND_SERVICE";
        NoNewPrivileges = true;
      };
    };
    systemd.services.asako-proxy-restore = {
      description = "Restore Asako TUN routing choice";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "sing-box-proxy.service" "asako-proxy-hk-guard.service" ];
      requires = [ "sing-box-proxy.service" "asako-proxy-hk-guard.service" ];
      wants = [ "network-online.target" ];
      environment = stateEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./proxy-state.py} restore ${if config.my.asakoProxy.defaultEnabled then "amane" else "off"}";
      };
    };
    systemd.services.asako-proxy-hk-guard = {
      description = "Guard Asako tailnet routes before native Tailscale starts";
      wantedBy = [ "tailscaled.service" ];
      requiredBy = [ "tailscaled.service" ];
      before = [ "tailscaled.service" ];
      environment = stateEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./proxy-state.py} guard";
      };
    };
    systemd.services.asako-proxy-enable = {
      description = "Enable Asako TUN routing";
      environment = stateEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./proxy-state.py} amane";
      };
    };
    systemd.services.asako-proxy-disable = {
      description = "Disable Asako TUN routing";
      environment = stateEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./proxy-state.py} off";
      };
    };
    systemd.services.asako-proxy-sachi = {
      description = "Route Asako TUN traffic through Sachi";
      environment = stateEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./proxy-state.py} sachi";
      };
    };
    systemd.services.asako-proxy-hk = {
      description = "Route Asako traffic through the Hong Kong TUN";
      environment = stateEnvironment;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python ${./proxy-state.py} hk";
      };
    };
  };
}
