{
  config,
  pkgs,
  lib,
  mylib,
  hostname,
  ...
}:

with lib;

let
  sachiOutbound = { type = "vless"; server_port = config.my.ports.xray.listen; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; domain_resolver = "local-dns"; tls = { enabled = true; server_name = "www.cloudflare.com"; utls = { enabled = true; fingerprint = "chrome"; }; reality = { enabled = true; public_key = "-6pvY7DzL_M7q-7fNeZZrnxosjIFyNPltVCo4rFu1yo"; short_id = "e5f60718"; }; }; };
  outbounds = [
    { type = "vless"; tag = "amane"; server = "direct.15cm.net"; server_port = config.my.ports.xray.listen; uuid = config.sops.placeholder.xrayClientId; flow = "xtls-rprx-vision"; domain_resolver = "local-dns"; tls = { enabled = true; server_name = "www.cloudflare.com"; utls = { enabled = true; fingerprint = "chrome"; }; reality = { enabled = true; public_key = "IM4pgDQbcql0ZIrzUWeU0HKE8GWbqsAV1t3c-PC20ks"; short_id = "a1b2c3d4"; }; }; }
    (sachiOutbound // { tag = "sachi-local"; server = "sachi.m.mado.moe"; })
    (sachiOutbound // { tag = "sachi-public"; server = "mado.moe"; })
    { type = "urltest"; tag = "sachi"; outbounds = [ "sachi-local" "sachi-public" ]; interval = "10s"; }
    { type = "selector"; tag = "proxy"; outbounds = [ "amane" "sachi" ]; default = "amane"; }
    { type = "direct"; tag = "direct"; }
  ];
in
{
  system.stateVersion = "22.05";
  # TUN routing starts off; choose `asako-proxy off|amane|sachi`.
  my.asakoProxy.defaultEnabled = false;
  imports = [
    ./hardware-configuration.nix
    ../common/baseline.nix
    ../common/boot-loader.nix
    ../common/users.nix
    ../common/trusted.nix
    ./proxy-options.nix
  ];

  environment.systemPackages = with pkgs; [
    easyrsa
    brightnessctl
    sing-box
    (pkgs.writeShellApplication {
      name = "asako-proxy";
      runtimeInputs = with pkgs; [ systemd coreutils ];
      text = ''
        set -euo pipefail
        case "''${1:-}" in
          amane|on) /run/wrappers/bin/sudo systemctl restart asako-proxy-enable.service ;;
          sachi) /run/wrappers/bin/sudo systemctl restart asako-proxy-sachi.service ;;
          off) /run/wrappers/bin/sudo systemctl restart asako-proxy-disable.service ;;
          status)
            /run/wrappers/bin/sudo systemctl status --no-pager sing-box-tun.service || true
            if [ -f /var/lib/asako-proxy/state ]; then
              echo "Boot choice: $(cat /var/lib/asako-proxy/state)"
            else
              echo "Boot choice: ${if config.my.asakoProxy.defaultEnabled then "amane" else "off"} (default)"
            fi
            ;;
          *) echo "Usage: asako-proxy off|amane|sachi|status" >&2; exit 2 ;;
        esac
      '';
    })
    (pkgs.writeShellApplication {
      name = "asako-sing-box-android-profiles";
      runtimeInputs = with pkgs; [ coreutils python3 ];
      text = ''
        umask 077
        uuid_file="''${MAKINA_XRAY_CLIENT_ID_FILE:-${config.sops.secrets.makinaXrayClientId.path}}"
        auth_keys_file="$(mktemp)"
        trap 'rm -f "$auth_keys_file"' EXIT
        python3 - "$auth_keys_file" \
          ${config.sops.secrets.makinaAmaneHeadscaleAuthKey.path} \
          ${config.sops.secrets.makinaSachiHeadscaleAuthKey.path} <<'PY'
        import json, sys
        output, amane_path, sachi_path = sys.argv[1:]
        def read(path):
            with open(path, encoding="utf-8") as source:
                return source.read().strip()
        keys = {
            "amane-normal-tailscale": read(amane_path),
            "amane-paypal-tailscale": read(amane_path),
            "sachi-normal-tailscale": read(sachi_path),
            "sachi-paypal-tailscale": read(sachi_path),
        }
        with open(output, "w", encoding="utf-8") as destination:
            json.dump(keys, destination)
        PY
        out="''${1:-/nas/storage/inbox}"
        if [ "$out" = /nas/storage/inbox ] && [ ! -d "$out" ]; then
          echo "NAS inbox is unavailable: $out" >&2
          exit 1
        fi
        python3 ${./android-profiles.py} "$uuid_file" "$out" "$auth_keys_file"
      '';
    })
  ];

  programs.proxychains = {
    enable = true;
    package = pkgs.proxychains-ng;
    chain.type = "strict";
    proxyDNS = true;
    proxies.xray-http = {
      enable = true;
      type = "http";
      host = "127.0.0.1";
      port = 10808;
    };
  };

  sops = {
    defaultSopsFile = ./secrets.yaml;
    secrets = {
      hashedPassword.neededForUsers = true;
      xrayClientId = { owner = "root"; group = "sinkerine"; mode = "0440"; };
      makinaXrayClientId = { owner = "root"; group = "sinkerine"; mode = "0440"; };
      makinaAmaneHeadscaleAuthKey = { owner = "root"; group = "sinkerine"; mode = "0440"; };
      makinaSachiHeadscaleAuthKey = { owner = "root"; group = "sinkerine"; mode = "0440"; };
    };
    templates."sing-box-proxy.json" = {
      owner = "root";
      group = "root";
      content = builtins.toJSON {
        log.level = "warn";
        dns.servers = [ { type = "local"; tag = "local-dns"; } ];
        inbounds = [
          { type = "socks"; tag = "socks-in"; listen = "127.0.0.1"; listen_port = 10809; }
          { type = "http"; tag = "http-in"; listen = "127.0.0.1"; listen_port = 10808; }
        ];
        outbounds = outbounds;
        http_clients = [ { tag = "rule-set-via-proxy"; detour = "proxy"; } ];
        route = { final = "proxy"; auto_detect_interface = true; default_domain_resolver = "local-dns"; rules = [ { rule_set = [ "geosite-cn" ]; action = "route"; outbound = "direct"; } { rule_set = [ "geoip-cn" ]; action = "route"; outbound = "direct"; } ]; rule_set = [
          { tag = "geosite-cn"; type = "remote"; format = "binary"; url = "https://github.com/SagerNet/sing-geosite/raw/rule-set/geosite-cn.srs"; http_client = "rule-set-via-proxy"; }
          { tag = "geoip-cn"; type = "remote"; format = "binary"; url = "https://github.com/SagerNet/sing-geoip/raw/rule-set/geoip-cn.srs"; http_client = "rule-set-via-proxy"; }
        ]; };
      };
      restartUnits = [ "sing-box-proxy.service" "sing-box-tun.service" ];
    };
    templates."sing-box-tun.json" = {
      owner = "root";
      group = "root";
      content = builtins.toJSON {
        log.level = "warn";
        experimental.clash_api = { external_controller = "127.0.0.1:19090"; };
        dns = { servers = [ { type = "local"; tag = "local-dns"; } { type = "https"; tag = "remote-dns"; server = "1.1.1.1"; path = "/dns-query"; detour = "proxy"; } ]; final = "remote-dns"; strategy = "prefer_ipv4"; };
        inbounds = [ { type = "tun"; tag = "tun-in"; interface_name = "singtun0"; address = [ "172.19.0.1/30" "fdfe:dcba:9876::1/126" ]; mtu = 9000; auto_route = true; strict_route = true; route_exclude_address = [ "10.0.0.0/8" "100.64.0.0/10" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "fd00::/8" "fe80::/10" ]; } ];
        outbounds = outbounds;
        route = { final = "proxy"; auto_detect_interface = true; default_domain_resolver = "local-dns"; rules = [ { protocol = "dns"; action = "hijack-dns"; } ]; };
      };
    };
    age = {
      keyFile = "/keys/age/${hostname}.txt";
      sshKeyPaths = [ ];
    };
    # https://github.com/Mic92/sops-nix/issues/167
    gnupg.sshKeyPaths = [ ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
    extraConfig = ''
      AllowUsers *@100.64.*.*
      AllowUsers *@192.168.88.*
    '';
  };

  boot.kernelPackages = mkForce pkgs.linuxPackages_6_18;
  # Work around amdgpu eDP/display hangs by disabling Panel Self Refresh.
  boot.kernelParams = [ "amdgpu.dcdebugmask=0x10" ];
  my.essentials.zfs = {
    enable = true;
    enableZed = true;
    enableZfsUnstable = true;
    arcMaxBytes = 8 * 1024 * 1024 * 1024;
  };
  my.essentials.gui.enable = true;

  networking = {
    hostName = hostname;
    domain = "mado.moe";
    # sing-box's TUN TCP stack accepts connections on its virtual interface.
    firewall.trustedInterfaces = [ "singtun0" ];
    networkmanager = {
      AllowUsers *@fd7a:115c:a1e0::/48
      enable = true;
    };
  };

  services.fwupd.enable = true;
  services.udisks2.enable = true;
  services.kmonad = {
    enable = true;
    keyboards = {
      laptop = {
        device = "/dev/input/by-path/platform-i8042-serio-0-event-kbd";
        defcfg = {
          enable = true;
          fallthrough = true;
          allowCommands = false;
        };
        config = builtins.readFile ./kmonad/laptop.kbd;
      };
    };
  };
  systemd.services.kmonad-laptop.serviceConfig = {
    Restart = "always";
      # Defaults for new and unmanaged profiles. Existing saved Wi-Fi profiles
      # retain their own IPv6 method and may need a one-time profile update.
      settings.connection = {
        "ipv6.method" = "auto";
        "ipv6.may-fail" = true;
      };
    RestartSec = "5";
  };

  # Disable the Radeon outputs in Pipewire so that the laptop speaker is selected by default.
  services.pipewire.wireplumber.extraConfig = {
    "disable-radeon-devices" = {
      "monitor.alsa.rules" = [
        {
          "matches" = [ { "device.name" = "alsa_card.pci-0000_63_00.1"; } ];
          "actions" = {
            "update-props" = {
              "device.disabled" = true;
            };
          };
        }
      ];
    };
  };

  # Laptop backlight brightness control via brightnessctl package
  # Laptop battery
  services.upower.enable = true;
  programs.virt-manager.enable = true;
  virtualisation.spiceUSBRedirection.enable = true;

  my.services.lock = {
    enable = true;
    lockService = "noctalia-lock.service";
  };

  services.logind.settings.Login = mkForce {
    HandleLidSwitch = "suspend";
    HandleLidSwitchDocked = "suspend";
    HandleLidSwitchExternalPower = "ignore";
  };

  my.services.zrepl = {
    enable = true;
    ports = { inherit (config.my.ports.zrepl.asako) push; };
    configTemplateFile = ./zrepl/zrepl.yaml.jinja;
    sopsCertFile = ./zrepl/asako.m.mado.moe.crt;
    sopsKeyFile = ./zrepl/asako.m.mado.moe.key;
  };

  my.services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
  };
  my.services.gateway = {
    enable = true;
    enableDocker = true;
    internalDomain = "${hostname}.m.mado.moe";
  };
  my.services.smartd.enable = true;
  my.services.metrics = {
    enable = true;
    enableScrapeSmartctl = true;
  };
}
    enableIPv6 = true;
    # Roaming interfaces are not trusted LANs. Tailscale and loopback remain
    # explicitly allowed by the gateway base policy.
    ipv6Interface = null;
    lanOnlyIpRanges = [ config.my.ip.ranges.local config.my.ip.ranges.tailscale ];
