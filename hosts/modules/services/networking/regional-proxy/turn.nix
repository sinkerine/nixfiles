{ config, lib, pkgs, ... }:

let
  cfg = config.my.services.regionalProxy;
  inherit (lib) mkIf mkOption types;
  turnDomain = "turn.matrix.15cm.net";
in
{
  options.my.services.regionalProxy.turnOptions = {
    publicIPv4 = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Public IPv4 address advertised by the TURN relay.";
    };
    sharedSecretFile = mkOption {
      type = types.str;
      default = "/run/secrets/matrix-turn-shared-secret";
      description = "Runtime path to the Synapse-compatible TURN shared secret.";
    };
    cloudflareTokenFile = mkOption {
      type = types.str;
      default = "/run/secrets/cloudflare-turn-acme-token";
      description = "Runtime file containing the Cloudflare DNS API token for ACME.";
    };
    ipv6Interface = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Interface used to discover a stable public IPv6 relay address.";
    };
    ipv6Dns.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Publish and reconcile the TURN AAAA record in Cloudflare.";
    };
  };

  config = mkIf cfg.turn {
    assertions = [
      {
        assertion = config.my.services.regionalProxy.turnOptions.publicIPv4 != null;
        message = "regionalProxy.turn requires regionalProxy.turnOptions.publicIPv4";
      }
      {
        assertion = !config.my.services.regionalProxy.turnOptions.ipv6Dns.enable
          || config.my.services.regionalProxy.turnOptions.ipv6Interface != null;
        message = "regionalProxy.turnOptions.ipv6Dns.enable requires ipv6Interface";
      }
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = "acme@15cm.net";
      certs.${turnDomain} = {
        dnsProvider = "cloudflare";
        credentialFiles = {
          CF_DNS_API_TOKEN_FILE = config.my.services.regionalProxy.turnOptions.cloudflareTokenFile;
          CF_ZONE_API_TOKEN_FILE = config.my.services.regionalProxy.turnOptions.cloudflareTokenFile;
        };
        group = "turnserver";
        reloadServices = [ "coturn.service" ];
      };
    };

    services.coturn = {
      enable = true;
      listening-port = 3478;
      tls-listening-port = 5349;
      min-port = 49160;
      max-port = 49200;
      use-auth-secret = true;
      static-auth-secret-file = config.my.services.regionalProxy.turnOptions.sharedSecretFile;
      realm = turnDomain;
      cert = "/var/lib/acme/${turnDomain}/fullchain.pem";
      pkey = "/var/lib/acme/${turnDomain}/key.pem";
      no-dtls = true;
      no-tcp-relay = true;
      extraConfig = ''
        include=/run/coturn/ipv6.conf
      '';
    };

    environment.etc."coturn/discover-ipv6.py".source = pkgs.writeText "coturn-discover-ipv6.py" ''
      import ipaddress, json, os, pathlib, subprocess, tempfile
      iface = os.environ.get("TURN_IPV6_INTERFACE", "")
      out = pathlib.Path("/run/coturn/ipv6.conf")
      state = pathlib.Path("/run/coturn/selected-ipv6")
      found = []
      if iface:
          try:
              rows = json.loads(subprocess.check_output(["${pkgs.iproute2}/bin/ip", "-j", "-6", "addr", "show", "dev", iface], text=True))
              for row in rows:
                  for a in row.get("addr_info", []):
                      if a.get("scope") != "global": continue
                      if a.get("valid_life_time", 1) == 0 or a.get("preferred_life_time", 1) == 0: continue
                      flags = set(a.get("flags", []))
                      if a.get("temporary") or a.get("tentative") or a.get("deprecated") or a.get("dadfailed"): continue
                      if flags & {"temporary", "tentative", "deprecated", "dadfailed"}: continue
                      try: ip = ipaddress.IPv6Address(a["local"])
                      except ValueError: continue
                      if ip.is_private or ip.is_link_local or ip.is_loopback or ip.is_unspecified: continue
                      found.append(str(ip))
          except Exception: pass
      found = sorted(set(found))
      selected = found[0] if len(found) == 1 else None
      out.parent.mkdir(mode=0o750, exist_ok=True)
      fd, tmp = tempfile.mkstemp(dir=str(out.parent), prefix="ipv6.")
      with os.fdopen(fd, "w") as f:
          f.write("listening-ip=${config.my.services.regionalProxy.turnOptions.publicIPv4}\n")
          f.write("relay-ip=${config.my.services.regionalProxy.turnOptions.publicIPv4}\n")
          f.write("external-ip=${config.my.services.regionalProxy.turnOptions.publicIPv4}/${config.my.services.regionalProxy.turnOptions.publicIPv4}\n")
          if selected:
              f.write(f"listening-ip={selected}\nrelay-ip={selected}\nexternal-ip={selected}/{selected}\n")
          else: f.write("no-ipv6\n")
          os.fchmod(f.fileno(), 0o640)
      os.replace(tmp, out)
      cfg = pathlib.Path("/run/coturn/turnserver.cfg")
      if cfg.exists():
          with cfg.open("a") as f:
              f.write(out.read_text())
      if selected: state.write_text(selected + "\n")
      elif state.exists(): state.unlink()
    '';

    systemd.services.coturn.preStart = lib.mkAfter ''
      install -d -m 0750 /run/coturn
      export TURN_IPV6_INTERFACE=${lib.escapeShellArg (if config.my.services.regionalProxy.turnOptions.ipv6Interface == null then "" else config.my.services.regionalProxy.turnOptions.ipv6Interface)}
      ${pkgs.python3}/bin/python ${config.environment.etc."coturn/discover-ipv6.py".source}
    '';

    environment.etc."coturn/reconcile-dns.py".source = pkgs.writeText "coturn-reconcile-dns.py" ''
      import ipaddress, json, os, pathlib, subprocess, urllib.request, urllib.parse
      token = pathlib.Path(os.environ["TURN_TOKEN"]).read_text().strip()
      domain = "turn.matrix.15cm.net"; zone = "15cm.net"; marker = "nixfiles-michiru-turn-ipv6"
      def readiness(address):
          route = subprocess.check_output(["${pkgs.iproute2}/bin/ip", "-6", "route", "get", "2606:4700:4700::1111", "from", address], text=True)
          if "unreachable" in route: raise RuntimeError("IPv6 egress unavailable")
          subprocess.run(["systemctl", "is-active", "--quiet", "coturn.service"], check=True)
          import socket, ssl
          ctx = ssl.create_default_context()
          with socket.create_connection((address, 5349), timeout=10) as raw:
              with ctx.wrap_socket(raw, server_hostname=domain): pass
      def api(method, path, body=None):
          req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path, method=method, headers={"Authorization":"Bearer "+token,"Content-Type":"application/json"}, data=None if body is None else json.dumps(body).encode())
          with urllib.request.urlopen(req, timeout=20) as r: return json.load(r)["result"]
      try:
          z = api("GET", "/zones?name="+zone+"&status=active")[0]["id"]
          rows = api("GET", f"/zones/{z}/dns_records?type=AAAA&name={urllib.parse.quote(domain)}&per_page=100")
          iface = os.environ.get("TURN_IPV6_INTERFACE", "")
          wanted = None
          if iface:
              rows6 = json.loads(subprocess.check_output(["${pkgs.iproute2}/bin/ip", "-j", "-6", "addr", "show", "dev", iface], text=True))
              candidates = []
              for row in rows6:
                  for a in row.get("addr_info", []):
                      if a.get("scope") != "global" or a.get("valid_life_time", 1) == 0 or a.get("preferred_life_time", 1) == 0: continue
                      if a.get("temporary") or a.get("tentative") or a.get("deprecated") or a.get("dadfailed"): continue
                      try: ip = ipaddress.IPv6Address(a["local"])
                      except ValueError: continue
                      if ip.is_private or ip.is_link_local or ip.is_loopback or ip.is_unspecified: continue
                      candidates.append(str(ip))
              candidates = sorted(set(candidates))
              wanted = candidates[0] if len(candidates) == 1 else None
          try: ipaddress.IPv6Address(wanted or "")
          except ValueError: wanted = None
          owned = [r for r in rows if (r.get("comment") or "") == marker]
          unmanaged = [r for r in rows if r not in owned]
          if unmanaged or len(owned) > 1: raise SystemExit("unmanaged or duplicate AAAA exists")
          current = owned[0] if owned else None
          if wanted: readiness(wanted)
          if current and (not wanted or current["content"] != wanted):
              api("DELETE", f"/zones/{z}/dns_records/{current['id']}"); current = None
              if wanted: subprocess.run(["systemctl", "restart", "coturn.service"], check=True)
          if wanted and not current:
              readiness(wanted)
              api("POST", f"/zones/{z}/dns_records", {"type":"AAAA","name":domain,"content":wanted,"ttl":120,"proxied":False,"comment":marker})
      except Exception as e:
          try:
              for record in locals().get("owned", []):
                  api("DELETE", f"/zones/{z}/dns_records/{record['id']}")
          except Exception: pass
          print("TURN DNS reconciliation failed:", type(e).__name__)
          raise
    '';
    systemd.services.coturn-ipv6-dns = {
      description = "Reconcile Michiru TURN IPv6 DNS";
      serviceConfig = { Type = "oneshot"; User = "root"; Environment = [ "TURN_TOKEN=${config.my.services.regionalProxy.turnOptions.cloudflareTokenFile}" "TURN_IPV6_INTERFACE=${if config.my.services.regionalProxy.turnOptions.ipv6Interface == null then "" else config.my.services.regionalProxy.turnOptions.ipv6Interface}" ]; ExecStart = "${pkgs.python3}/bin/python ${config.environment.etc."coturn/reconcile-dns.py".source}"; };
    };
    systemd.timers.coturn-ipv6-dns = mkIf config.my.services.regionalProxy.turnOptions.ipv6Dns.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "2min"; Unit = "coturn-ipv6-dns.service"; };
    };

    systemd.services.coturn = {
      requires = [ "acme-order-renew-${turnDomain}.service" ];
      after = [ "acme-order-renew-${turnDomain}.service" ];
    };

    networking.firewall = {
      allowedUDPPorts = [ 3478 ];
      allowedTCPPorts = [ 3478 5349 ];
      allowedUDPPortRanges = [ { from = 49160; to = 49200; } ];
    };
  };
}
