{ config, pkgs, ... }:

let
  exporter = pkgs.writeShellApplication {
    name = "makina-sing-box-android-profiles";
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
          "amane-tailscale": read(amane_path),
          "amane-paypal-tailscale": read(amane_path),
          "sachi-tailscale": read(sachi_path),
          "sachi-paypal-tailscale": read(sachi_path),
          "michiru-cn-direct-tailscale": read(sachi_path),
      }
      with open(output, "w", encoding="utf-8") as destination:
          json.dump(keys, destination)
      PY
      out="''${1:-/nas/storage/inbox/singbox}"
      if [ -z "''${MICHIRU_PROFILE_CONFIG_FILE:-}" ] && [ -r ${config.sops.templates."makina-hk.json".path} ]; then
        export MICHIRU_PROFILE_CONFIG_FILE=${config.sops.templates."makina-hk.json".path}
      fi
      if [ "$out" = /nas/storage/inbox/singbox ] && [ ! -d /nas/storage/inbox ]; then
        echo "NAS inbox is unavailable: /nas/storage/inbox" >&2
        exit 1
      fi
      export REALITY_SNI_TARGETS_FILE=${../common/reality-sni-targets.json}
      export REALITY_PRIMARY_TARGETS_FILE=${../common/reality-primary-targets.json}
      python3 ${./android-profiles.py} "$uuid_file" "$out" "$auth_keys_file"
    '';
  };
in
{
  environment.systemPackages = [ exporter ];

  sops = {
    secrets = {
      makinaXrayClientId = {
        sopsFile = ./secrets.yaml;
        owner = "root";
        group = "sinkerine";
        mode = "0440";
      };
      makinaAmaneHeadscaleAuthKey = {
        sopsFile = ./secrets.yaml;
        owner = "root";
        group = "sinkerine";
        mode = "0440";
      };
      makinaSachiHeadscaleAuthKey = {
        sopsFile = ./secrets.yaml;
        owner = "root";
        group = "sinkerine";
        mode = "0440";
      };
      makinaHKProfile = {
        sopsFile = ../michiru/relay-secrets.yaml;
        key = "asakoHKProfile";
        owner = "root";
        group = "sinkerine";
        mode = "0440";
      };
    };
    templates."makina-hk.json" = {
      owner = "root";
      group = "sinkerine";
      mode = "0440";
      content = config.sops.placeholder.makinaHKProfile;
    };
  };
}
