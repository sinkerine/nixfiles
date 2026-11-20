{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.my.services.realityGuard;

  domainType =
    lib.types.addCheck
      (lib.types.strMatching "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
      (d: builtins.stringLength d <= 253)
    // {
      description = "valid lowercase DNS hostname (<= 253 chars, at least one dot, no leading/trailing hyphen)";
    };

  tierSubmodule =
    defaults:
    lib.types.submodule {
      options = {
        bandwidthRate = lib.mkOption {
          type = lib.types.str;
          default = defaults.bandwidthRate;
          description = "nftables byte rate limit (e.g. \"256 kbytes/second\").";
        };
        bandwidthBurst = lib.mkOption {
          type = lib.types.str;
          default = defaults.bandwidthBurst;
          description = "nftables byte burst size (e.g. \"512 kbytes\").";
        };
        perConnAllowance = lib.mkOption {
          type = lib.types.ints.positive;
          default = defaults.perConnAllowance;
          description = "Unconditional bidirectional byte allowance per flow before bandwidth policing.";
        };
        perConnQuota = lib.mkOption {
          type = lib.types.ints.positive;
          default = defaults.perConnQuota;
          description = "Maximum total bidirectional bytes per flow before hard drop.";
        };
      };
    };

  formatSetElements = items: lib.concatMapStringsSep ", " (item: "\"${item}\"") items;
  formatPortElements = ports: lib.concatMapStringsSep ", " toString ports;

  passwdFile = pkgs.writeText "reality-guard-passwd" ''
    root:x:0:0::/root:/bin/sh
    ${cfg.singBoxUser}:x:999:999::/:/sbin/nologin
  '';

  rulesText = ''
    table inet reality_guard
    delete table inet reality_guard

    table inet reality_guard {
      limit strict_bw {
        rate over ${cfg.strict.bandwidthRate} burst ${cfg.strict.bandwidthBurst}
      }
      limit relaxed_bw {
        rate over ${cfg.relaxed.bandwidthRate} burst ${cfg.relaxed.bandwidthBurst}
      }

      counter strict_bw_out_drop {}
      counter strict_bw_in_drop {}
      counter strict_quota_out_drop {}
      counter strict_quota_in_drop {}
      counter relaxed_bw_out_drop {}
      counter relaxed_bw_in_drop {}
      counter relaxed_quota_out_drop {}
      counter relaxed_quota_in_drop {}
      counter inbound_rate_drop {}
      counter inbound_conn_drop {}

      set decoy_strict_v4 {
        type ipv4_addr
      }
      set decoy_strict_v6 {
        type ipv6_addr
      }
      set decoy_relaxed_v4 {
        type ipv4_addr
      }
      set decoy_relaxed_v6 {
        type ipv6_addr
      }

      ${lib.optionalString (cfg.inboundPorts != [ ]) ''
        set public_ports {
          type inet_service
          elements = { ${formatPortElements cfg.inboundPorts} }
        }
      ''}

      ${lib.optionalString (cfg.inbound.exemptInterfaces != [ ]) ''
        set exempt_ifaces {
          type ifname
          elements = { ${formatSetElements cfg.inbound.exemptInterfaces} }
        }
      ''}

      set inbound_rate_v4 {
        type ipv4_addr
        size 65535
        flags dynamic, timeout
        timeout 5m
      }
      set inbound_rate_v6 {
        type ipv6_addr
        size 65535
        flags dynamic, timeout
        timeout 5m
      }
      set inbound_conn_v4 {
        type ipv4_addr
        size 65535
        flags dynamic
      }
      set inbound_conn_v6 {
        type ipv6_addr
        size 65535
        flags dynamic
      }

      chain decoy_strict_out {
        ct bytes > ${toString cfg.strict.perConnQuota} counter name "strict_quota_out_drop" reject with tcp reset
        ct bytes <= ${toString cfg.strict.perConnAllowance} accept
        limit name "strict_bw" counter name "strict_bw_out_drop" drop
        accept
      }

      chain decoy_relaxed_out {
        ct bytes > ${toString cfg.relaxed.perConnQuota} counter name "relaxed_quota_out_drop" reject with tcp reset
        ct bytes <= ${toString cfg.relaxed.perConnAllowance} accept
        limit name "relaxed_bw" counter name "relaxed_bw_out_drop" drop
        accept
      }

      chain decoy_strict_classify_out {
        ct mark set ct mark | 0x00100000
        jump decoy_strict_out
        accept
      }

      chain decoy_relaxed_classify_out {
        ct mark set ct mark | 0x00200000
        jump decoy_relaxed_out
        accept
      }

      chain output {
        type filter hook output priority filter + 10; policy accept;
        oifname "lo" accept
        meta l4proto tcp ct direction original ct mark & 0x00100000 != 0 jump decoy_strict_out
        meta l4proto tcp ct direction original ct mark & 0x00200000 != 0 jump decoy_relaxed_out
        ct state new meta skuid "${cfg.singBoxUser}" tcp dport 443 ip daddr @decoy_strict_v4 jump decoy_strict_classify_out
        ct state new meta skuid "${cfg.singBoxUser}" tcp dport 443 ip6 daddr @decoy_strict_v6 jump decoy_strict_classify_out
        ct state new meta skuid "${cfg.singBoxUser}" tcp dport 443 ip daddr @decoy_relaxed_v4 jump decoy_relaxed_classify_out
        ct state new meta skuid "${cfg.singBoxUser}" tcp dport 443 ip6 daddr @decoy_relaxed_v6 jump decoy_relaxed_classify_out
      }

      chain input {
        type filter hook input priority filter + 10; policy accept;
        ${lib.optionalString (cfg.inbound.exemptInterfaces != [ ]) ''
          iifname @exempt_ifaces accept
        ''}
        meta l4proto tcp ct mark & 0x00100000 != 0 ct bytes > ${toString cfg.strict.perConnQuota} counter name "strict_quota_in_drop" reject with tcp reset
        meta l4proto tcp ct mark & 0x00100000 != 0 ct bytes > ${toString cfg.strict.perConnAllowance} limit name "strict_bw" counter name "strict_bw_in_drop" drop
        meta l4proto tcp ct mark & 0x00200000 != 0 ct bytes > ${toString cfg.relaxed.perConnQuota} counter name "relaxed_quota_in_drop" reject with tcp reset
        meta l4proto tcp ct mark & 0x00200000 != 0 ct bytes > ${toString cfg.relaxed.perConnAllowance} limit name "relaxed_bw" counter name "relaxed_bw_in_drop" drop
        ${lib.optionalString (cfg.inboundPorts != [ ]) ''
          meta nfproto ipv4 ct state new tcp dport @public_ports update @inbound_rate_v4 { ip saddr limit rate over ${cfg.inbound.newConnRate} burst ${toString cfg.inbound.newConnBurst} packets } counter name "inbound_rate_drop" drop
          meta nfproto ipv6 ct state new tcp dport @public_ports update @inbound_rate_v6 { ip6 saddr limit rate over ${cfg.inbound.newConnRate} burst ${toString cfg.inbound.newConnBurst} packets } counter name "inbound_rate_drop" drop
          meta nfproto ipv4 ct state new tcp dport @public_ports add @inbound_conn_v4 { ip saddr ct count over ${toString cfg.inbound.maxConnections} } counter name "inbound_conn_drop" drop
          meta nfproto ipv6 ct state new tcp dport @public_ports add @inbound_conn_v6 { ip6 saddr ct count over ${toString cfg.inbound.maxConnections} } counter name "inbound_conn_drop" drop
        ''}
      }
    }
  '';

  rulesFile = pkgs.writeTextFile {
    name = "reality-guard.nft";
    text = rulesText;
    checkPhase = ''
      export NIX_REDIRECTS="/etc/passwd=${passwdFile}:/etc/protocols=${pkgs.iana-etc}/etc/protocols:/etc/services=${pkgs.iana-etc}/etc/services"
      LD_PRELOAD="${pkgs.buildPackages.libredirect}/lib/libredirect.so ${pkgs.buildPackages.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
        ${pkgs.buildPackages.nftables}/bin/nft --check --file "$out"
    '';
  };

  resolveConfig = pkgs.writeText "reality-guard-resolve.json" (
    builtins.toJSON {
      strictDomains = cfg.strictDomains;
      relaxedDomains = cfg.relaxedDomains;
      ipRetentionSeconds = cfg.ipRetentionSeconds;
      cacheFile = "/var/lib/reality-guard/cache.json";
      lockFile = "/var/lib/reality-guard/lock";
    }
  );

  resolveScript = ./reality-guard-resolve.py;
in
{
  options.my.services.realityGuard = {
    enable = lib.mkEnableOption "REALITY fallback traffic and inbound scan guard";

    singBoxUser = lib.mkOption {
      type = lib.types.str;
      default = "sing-box";
      description = "System user running sing-box whose outbound decoy traffic is policed.";
    };

    strictDomains = lib.mkOption {
      type = lib.types.listOf domainType;
      default = [ ];
      description = "Primary REALITY decoy domains policed under the strict tier.";
    };

    relaxedDomains = lib.mkOption {
      type = lib.types.listOf domainType;
      default = [ ];
      description = "Secondary/captive REALITY decoy domains policed under the relaxed tier.";
    };

    inboundPorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ ];
      description = "Public REALITY TCP ports protected by per-source-IP inbound scan limits.";
    };

    resolveInterval = lib.mkOption {
      type = lib.types.str;
      default = "5min";
      description = "Systemd timer interval for periodic decoy DNS resolution.";
    };

    ipRetentionSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Seconds to retain previously resolved decoy IPs across rotating DNS answers.";
    };

    strict = lib.mkOption {
      type = tierSubmodule {
        bandwidthRate = "256 kbytes/second";
        bandwidthBurst = "512 kbytes";
        perConnAllowance = 32 * 1024;
        perConnQuota = 1024 * 1024;
      };
      default = { };
      description = "Strict-tier egress fallback limits.";
    };

    relaxed = lib.mkOption {
      type = tierSubmodule {
        bandwidthRate = "5 mbytes/second";
        bandwidthBurst = "10 mbytes";
        perConnAllowance = 32 * 1024;
        perConnQuota = 64 * 1024 * 1024;
      };
      default = { };
      description = "Relaxed-tier egress fallback limits.";
    };

    inbound = lib.mkOption {
      type = lib.types.submodule {
        options = {
          newConnRate = lib.mkOption {
            type = lib.types.str;
            default = "60/second";
            description = "Per-source-IP new-connection rate limit on inboundPorts.";
          };
          newConnBurst = lib.mkOption {
            type = lib.types.ints.positive;
            default = 150;
            description = "Per-source-IP new-connection burst packets on inboundPorts.";
          };
          maxConnections = lib.mkOption {
            type = lib.types.ints.positive;
            default = 512;
            description = "Per-source-IP maximum concurrent connections on inboundPorts.";
          };
          exemptInterfaces = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              "lo"
              "tailscale0"
            ];
            description = "Interfaces exempted from inbound guard and return policing.";
          };
        };
      };
      default = { };
      description = "Inbound per-source-IP scan protection settings.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "nf_conntrack" ];
    boot.kernel.sysctl."net.netfilter.nf_conntrack_acct" = 1;

    assertions = [
      {
        assertion = cfg.singBoxUser != "";
        message = "my.services.realityGuard.singBoxUser must not be empty.";
      }
      {
        assertion =
          cfg.strictDomains != [ ] || cfg.relaxedDomains != [ ] || cfg.inboundPorts != [ ];
        message = "my.services.realityGuard requires at least one of strictDomains, relaxedDomains, or inboundPorts.";
      }
      {
        assertion = lib.all (d: d != "") cfg.strictDomains;
        message = "my.services.realityGuard.strictDomains must not contain empty strings.";
      }
      {
        assertion = lib.all (d: d != "") cfg.relaxedDomains;
        message = "my.services.realityGuard.relaxedDomains must not contain empty strings.";
      }
      {
        assertion = lib.all (i: i != "") cfg.inbound.exemptInterfaces;
        message = "my.services.realityGuard.inbound.exemptInterfaces must not contain empty strings.";
      }
      {
        assertion = cfg.strict.perConnAllowance <= cfg.strict.perConnQuota;
        message = "my.services.realityGuard.strict.perConnAllowance must not exceed strict.perConnQuota.";
      }
      {
        assertion = cfg.relaxed.perConnAllowance <= cfg.relaxed.perConnQuota;
        message = "my.services.realityGuard.relaxed.perConnAllowance must not exceed relaxed.perConnQuota.";
      }
    ];

    systemd.services.reality-guard-nft = {
      description = "REALITY Fallback Guard nftables table";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-pre.target" ];
      before = [
        "network.target"
        "sing-box-server.service"
        "sing-box-hk-relay.service"
      ];
      reloadIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "reality-guard";
        StateDirectoryMode = "0750";
        Environment = [ "NFT_BIN=${pkgs.nftables}/bin/nft" ];
        ExecStartPre = [
          "${pkgs.kmod}/bin/modprobe nf_conntrack"
          "${pkgs.procps}/bin/sysctl -w net.netfilter.nf_conntrack_acct=1"
          "${pkgs.bash}/bin/sh -c 'test \"$(cat /proc/sys/net/netfilter/nf_conntrack_acct)\" = 1'"
        ];
        ExecStart = "${pkgs.python3}/bin/python3 ${resolveScript} --render-ruleset ${rulesFile} ${resolveConfig}";
        ExecReload = [
          "${pkgs.kmod}/bin/modprobe nf_conntrack"
          "${pkgs.procps}/bin/sysctl -w net.netfilter.nf_conntrack_acct=1"
          "${pkgs.bash}/bin/sh -c 'test \"$(cat /proc/sys/net/netfilter/nf_conntrack_acct)\" = 1'"
          "${pkgs.python3}/bin/python3 ${resolveScript} --render-ruleset ${rulesFile} ${resolveConfig}"
        ];
        ExecStop = "-${pkgs.nftables}/bin/nft delete table inet reality_guard";
      };
    };

    systemd.services.reality-guard-resolve = {
      description = "Resolve REALITY decoy domains for reality-guard";
      wantedBy = [ "multi-user.target" ];
      after = [
        "reality-guard-nft.service"
        "network-online.target"
      ];
      requires = [ "reality-guard-nft.service" ];
      wants = [ "network-online.target" ];
      restartTriggers = [ resolveConfig ];
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "reality-guard";
        StateDirectoryMode = "0750";
        TimeoutStartSec = "30s";
        Environment = [ "NFT_BIN=${pkgs.nftables}/bin/nft" ];
        ExecStart = "${pkgs.python3}/bin/python3 ${resolveScript} ${resolveConfig}";
      };
    };

    systemd.timers.reality-guard-resolve = {
      description = "Periodic DNS resolution for reality-guard";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = cfg.resolveInterval;
        RandomizedDelaySec = "15s";
      };
    };
  };
}
