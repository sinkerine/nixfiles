#!/usr/bin/env bash
set -euo pipefail
umask 077

here=$(cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd -- "$here/../../../../../.." && pwd)
secrets=${REGIONAL_PROXY_ROUTEROS_SECRETS:-"$here/routeros-secrets.yaml"}
peer_pub=${MICHIRU_PEER_PUBLIC_KEY_FILE:-"$repo/hosts/michiru/routeros-peer.pub"}
router=${ROUTEROS_SSH_TARGET:-router}
list_generator=${REGIONAL_PROXY_LIST_GENERATOR:-"$here/update-sources.sh"}
runtime_dir=${REGIONAL_PROXY_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run}}
us_exit_source=${REGIONAL_PROXY_USEXIT_SOURCE_IPV4:-192.168.88.31}
remote_file="regional-hk-import-$(date +%s%N)-$$-${RANDOM}.rsc"

normalize_routeros() {
  local value=$1
  value=${value//$'\r'/}
  value=${value//$'\n'/}
  printf '%s' "$value"
}

router_count() {
  local command=$1 value
  value=$(ssh "$router" "$command" 2>/dev/null) || return 1
  normalize_routeros "$value"
}

require_router_count() {
  local description=$1 command=$2 expected=$3 value
  value=$(router_count "$command") || { echo "RouterOS verification failed: $description query failed" >&2; return 1; }
  [[ "$value" == "$expected" ]] || {
    echo "RouterOS verification failed: $description expected $expected, found ${value:-empty}; inspect partial import before retry" >&2
    return 1
  }
}

case "${1:-}" in
  install)
    for tool in ssh scp sops python3; do command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }; done
    [[ -r "$secrets" ]] || { echo "encrypted RouterOS secrets missing: $secrets" >&2; exit 1; }
    [[ -r "$peer_pub" ]] || { echo "Michiru peer public key missing: $peer_pub" >&2; exit 1; }
    version=$(ssh "$router" ':put [/system resource get version]' 2>/dev/null) || { echo "RouterOS version preflight failed" >&2; exit 1; }
    version=$(normalize_routeros "$version")
    python3 - "$version" <<'PY'
import re, sys
match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", sys.argv[1])
if not match or tuple(map(int, (match.group(1), match.group(2), match.group(3) or 0))) < (7, 16, 0):
    raise SystemExit("RouterOS 7.16.0 or newer required; no configuration changed")
PY
    dns_state=$(ssh "$router" ':put [/ip dns get allow-remote-requests]' 2>/dev/null) || { echo "RouterOS DNS preflight failed" >&2; exit 1; }
    dns_state=$(normalize_routeros "$dns_state")
    [[ "$dns_state" == "yes" || "$dns_state" == "true" ]] || { echo "RouterOS must already have allow-remote-requests enabled; no configuration changed" >&2; exit 1; }
    existing=$(ssh "$router" '/system script print count-only where name="regional-hk-on"' 2>/dev/null) || { echo "RouterOS preflight failed" >&2; exit 1; }
    existing=$(normalize_routeros "$existing")
    [[ "$existing" == 0 ]] || { echo "regional-HK scripts already installed; remove owned config before reinstall" >&2; exit 1; }
    require_router_count "regional WireGuard interface preflight" '/interface wireguard print count-only where name="wg-regional-hk"' 0 || exit 1
    require_router_count "regional routing table preflight" '/routing table print count-only where name="hk-cn"' 0 || exit 1
    require_router_count "regional owned firewall/DNS preflight" '/ip firewall mangle print count-only where comment="regional-hk-owned"' 0 || exit 1
    require_router_count "regional owned NAT preflight" '/ip firewall nat print count-only where comment="regional-hk-owned"' 0 || exit 1
    require_router_count "regional owned address-list preflight" '/ip firewall address-list print count-only where comment="regional-hk-owned"' 0 || exit 1
    require_router_count "regional owned DNS preflight" '/ip dns static print count-only where comment="regional-hk-owned"' 0 || exit 1
    require_router_count "regional owned IPv6 preflight" '/ipv6 firewall filter print count-only where comment="regional-hk-owned"' 0 || exit 1
    # RouterOS CLI parses dotted CIDR literals as expressions unless quoted.
    dhcp_count=$(ssh "$router" '/ip dhcp-server network print count-only where address="192.168.88.0/24"' 2>/dev/null) || { echo "main-LAN DHCP preflight failed" >&2; exit 1; }
    fasttrack_count=$(ssh "$router" '/ip firewall filter print count-only where comment="defconf: fasttrack" and action=fasttrack-connection' 2>/dev/null) || { echo "FastTrack preflight failed" >&2; exit 1; }
    dhcp_count=$(normalize_routeros "$dhcp_count")
    fasttrack_count=$(normalize_routeros "$fasttrack_count")
    [[ "$dhcp_count" == 1 && "$fasttrack_count" == 1 ]] || { echo "expected one main-LAN DHCP network and one default FastTrack rule; no configuration changed" >&2; exit 1; }
    dhcp_dns=$(ssh "$router" ':put [/ip dhcp-server network get [find where address="192.168.88.0/24"] dns-server]' 2>/dev/null) || { echo "main-LAN DHCP DNS preflight failed" >&2; exit 1; }
    fasttrack_mark=$(ssh "$router" ':put [/ip firewall filter get [find where comment="defconf: fasttrack" and action=fasttrack-connection] connection-mark]' 2>/dev/null) || { echo "FastTrack baseline preflight failed" >&2; exit 1; }
    dhcp_dns=$(normalize_routeros "$dhcp_dns")
    fasttrack_mark=$(normalize_routeros "$fasttrack_mark")
    [[ "$dhcp_dns" =~ ^[0-9A-Fa-f.:,[:space:]]*$ ]] || { echo "unsupported main-LAN DHCP DNS value; no configuration changed" >&2; exit 1; }
    [[ "$fasttrack_mark" =~ ^[A-Za-z0-9_.-]*$ ]] || { echo "unsupported FastTrack connection-mark value; no configuration changed" >&2; exit 1; }
    tmp=$(mktemp -d "$runtime_dir/regional-hk.XXXXXX")
    uploaded=0
    cleanup() {
      status=$?
      for sensitive in "$tmp/router.key" "$tmp/import.rsc"; do
        [[ ! -e "$sensitive" ]] || shred -u -- "$sensitive" 2>/dev/null || true
      done
      python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
directory = Path(sys.argv[1])
for entry in directory.iterdir():
    if entry.is_file() or entry.is_symlink():
        entry.unlink()
directory.rmdir()
PY
      if [[ $uploaded == 1 ]]; then
        if ! ssh "$router" "/file remove [find where name=\"$remote_file\"]" >/dev/null 2>&1; then
          echo "failed to remove remote temporary file $remote_file; remove it manually on RouterOS" >&2
          cleanup_failed=1
        fi
      fi
      if [[ $cleanup_failed == 1 && $status == 0 ]]; then exit 1; fi
      return "$status"
    }
    cleanup_failed=0
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    sops --extract '["wireguardPrivateKey"]' --decrypt "$secrets" > "$tmp/router.key"
    chmod 0600 "$tmp/router.key"
    "$list_generator" "$tmp/lists.rsc"
    python3 - "$here/regional-hk-base.rsc" "$tmp/lists.rsc" "$tmp/router.key" "$peer_pub" "$tmp/import.rsc" "$us_exit_source" "$dhcp_dns" "$fasttrack_mark" <<'PY'
import base64
import ipaddress
from pathlib import Path
import sys

base_path, lists_path, router_key_path, peer_path, output_path = map(Path, sys.argv[1:6])
source_address = str(ipaddress.IPv4Address(sys.argv[6]))
base = base_path.read_text()
key = router_key_path.read_text().strip()
peer = peer_path.read_text().strip()
try:
    peer_bytes = base64.b64decode(peer, validate=True)
except ValueError as error:
    raise SystemExit("Michiru peer file must contain a raw WireGuard public key") from error
try:
    key_bytes = base64.b64decode(key, validate=True)
except ValueError as error:
    raise SystemExit("RouterOS private key must be valid base64") from error
if len(key_bytes) != 32 or len(peer_bytes) != 32:
    raise SystemExit("WireGuard keys must each decode to exactly 32 bytes")
def ros_quote(value):
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$")

base = (base.replace("__HK_ROUTER_PRIVATE_KEY__", key)
        .replace("__MICHIRU_PUBLIC_KEY__", peer)
        .replace("__US_EXIT_SOURCE_IPV4__", source_address)
        .replace("__ORIGINAL_DHCP_DNS__", ros_quote(sys.argv[7]))
        .replace("__ORIGINAL_FASTTRACK_MARK__", ros_quote(sys.argv[8])))
if any(token in base for token in ("__HK_ROUTER_PRIVATE_KEY__", "__MICHIRU_PUBLIC_KEY__", "__US_EXIT_SOURCE_IPV4__", "__ORIGINAL_DHCP_DNS__", "__ORIGINAL_FASTTRACK_MARK__")):
    raise SystemExit("unexpanded credential placeholder")
output_path.write_text(base + "\n" + lists_path.read_text())
PY
    expected_dns=$((2 + $(wc -l < "$tmp/lists.rsc")))
    chmod 0600 "$tmp/import.rsc"
    uploaded=1
    scp -q "$tmp/import.rsc" "$router:$remote_file"
    if ! ssh "$router" "/import file-name=$remote_file" >/dev/null 2>&1; then
      echo "RouterOS import failed; exit cleanup will remove local files and attempt remote upload deletion; inspect router for partial objects before retry" >&2
      exit 1
    fi
    # RouterOS SSH reports exit status 0 even when its importer logs a script
    # parse error. Verify the critical installed objects and disabled state.
    require_router_count "regional WireGuard interface" '/interface wireguard print count-only where name="wg-regional-hk" and disabled=yes' 1 || exit 1
    require_router_count "regional WireGuard address" '/ip address print count-only where interface="wg-regional-hk" and disabled=yes' 1 || exit 1
    require_router_count "regional WireGuard peer" '/interface wireguard peers print count-only where interface="wg-regional-hk" and disabled=yes' 1 || exit 1
    require_router_count "regional routing table" '/routing table print count-only where name="hk-cn"' 1 || exit 1
    require_router_count "regional routes" '/ip route print count-only where routing-table="hk-cn" and comment="regional-hk-owned" and disabled=yes' 2 || exit 1
    require_router_count "regional address-list entries" '/ip firewall address-list print count-only where comment="regional-hk-owned" and disabled=yes' 16 || exit 1
    require_router_count "regional mangle rules" '/ip firewall mangle print count-only where comment="regional-hk-owned" and disabled=yes' 5 || exit 1
    require_router_count "regional NAT rules" '/ip firewall nat print count-only where comment="regional-hk-owned" and disabled=yes' 3 || exit 1
    require_router_count "regional DNS static entries" '/ip dns static print count-only where comment="regional-hk-owned" and disabled=yes' "$expected_dns" || exit 1
    require_router_count "regional IPv6 block absent" '/ipv6 firewall filter print count-only where comment="regional-hk-owned"' 0 || exit 1
    require_router_count "regional state scripts" '/system script print count-only where name~"regional-hk"' 4 || exit 1
    for command in \
      '/ip firewall mangle print count-only where comment="regional-hk-owned" and disabled=no' \
      '/ip firewall nat print count-only where comment="regional-hk-owned" and disabled=no' \
      '/ip firewall address-list print count-only where comment="regional-hk-owned" and disabled=no' \
      '/ip dns static print count-only where comment="regional-hk-owned" and disabled=no' \
      '/ipv6 firewall filter print count-only where comment="regional-hk-owned" and disabled=no'; do
      require_router_count "enabled owned objects" "$command" 0 || exit 1
    done
    echo "Disabled regional-HK configuration imported. RouterOS traffic remains unchanged until regional-hk-on is invoked."
    ;;
  refresh-on)
    for tool in ssh scp python3; do command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 1; }; done
    require_router_count "installed regional on script" '/system script print count-only where name="regional-hk-on"' 1 || exit 1
    require_router_count "regional interface remains disabled before script update" '/interface wireguard print count-only where name="wg-regional-hk" and disabled=yes' 1 || exit 1
    tmp=$(mktemp -d "$runtime_dir/regional-hk-refresh.XXXXXX")
    uploaded=0
    cleanup_failed=0
    cleanup() {
      status=$?
      rm -f -- "$tmp/refresh-on.rsc"
      rmdir -- "$tmp" 2>/dev/null || true
      if [[ $uploaded == 1 ]] && ! ssh "$router" "/file remove [find where name=\"$remote_file\"]" >/dev/null 2>&1; then
        echo "failed to remove remote temporary file $remote_file; remove it manually on RouterOS" >&2
        cleanup_failed=1
      fi
      if [[ $cleanup_failed == 1 && $status == 0 ]]; then exit 1; fi
      return "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' HUP INT TERM
    python3 - "$here/regional-hk-base.rsc" "$tmp/refresh-on.rsc" <<'PY'
from pathlib import Path
import sys

base = Path(sys.argv[1]).read_text()
output = Path(sys.argv[2])
start = base.index("/system script add name=regional-hk-on")
body_start = base.index("source={", start) + len("source={")
body_end = base.index("\n}", body_start)
source = base[body_start:body_end]
if "connection remove" in source:
    raise SystemExit("regional-hk-on must preserve existing connections")
command = (
    '/system script set [find where name="regional-hk-on"] '
    'comment="regional-hk-owned" policy=read,write,test source={'
    + source
    + "\n}\n"
)
output.write_text(command)
PY
    chmod 0600 "$tmp/refresh-on.rsc"
    scp -q "$tmp/refresh-on.rsc" "$router:$remote_file"
    uploaded=1
    if ! ssh "$router" "/import file-name=$remote_file" >/dev/null 2>&1; then
      echo "RouterOS on-script update failed; temporary files will be removed; inspect script state before retry" >&2
      exit 1
    fi
    require_router_count "regional interface remains disabled after script update" '/interface wireguard print count-only where name="wg-regional-hk" and disabled=yes' 1 || exit 1
    require_router_count "updated regional on script" '/system script print count-only where name="regional-hk-on"' 1 || exit 1
    on_flush=$(ssh "$router" ':put [:find [/system script get [find where name="regional-hk-on"] source] "connection remove"]' 2>/dev/null) || { echo "RouterOS on-script verification query failed" >&2; exit 1; }
    on_flush=$(normalize_routeros "$on_flush")
    [[ -z "$on_flush" || "$on_flush" == "nil" || "$on_flush" == "-1" ]] || { echo "updated regional-hk-on still removes connections; activation refused" >&2; exit 1; }
    on_marker=$(ssh "$router" ':put [:find [/system script get [find where name="regional-hk-on"] source] "regional-hk-state"]' 2>/dev/null) || { echo "RouterOS on-script verification query failed" >&2; exit 1; }
    on_marker=$(normalize_routeros "$on_marker")
    [[ "$on_marker" =~ ^[0-9]+$ ]] || { echo "updated regional-hk-on missing expected state initialization; activation refused" >&2; exit 1; }
    echo "Updated regional-hk-on verified; activation preserves existing connections."
    ;;
  allowlist)
    python3 "$here/allowlist.py" apply --router "$router"
    ;;
  on)
    ssh "$router" '/system script run regional-hk-on'
    ;;
  off)
    ssh "$router" '/system script run regional-hk-off'
    # RouterOS SSH can exit 0 even when the script stops at a runtime error.
    # Verify the live cutover objects, especially NAT and the tunnel, before
    # reporting that the old WAN path has been restored.
    require_router_count "enabled regional mangle rules" '/ip firewall mangle print count-only where comment="regional-hk-owned" and disabled=no' 0
    require_router_count "enabled regional NAT rules" '/ip firewall nat print count-only where comment="regional-hk-owned" and disabled=no' 0
    require_router_count "enabled regional DNS entries" '/ip dns static print count-only where comment="regional-hk-owned" and disabled=no' 0
    require_router_count "enabled regional address-list entries" '/ip firewall address-list print count-only where comment="regional-hk-owned" and disabled=no and dynamic=no' 0
    require_router_count "enabled regional IPv6 rules" '/ipv6 firewall filter print count-only where comment="regional-hk-owned" and disabled=no' 0
    require_router_count "enabled regional routes" '/ip route print count-only where comment="regional-hk-owned" and disabled=no' 0
    require_router_count "enabled regional WireGuard address" '/ip address print count-only where comment="regional-hk-owned" and disabled=no' 0
    require_router_count "enabled regional WireGuard interface" '/interface wireguard print count-only where name="wg-regional-hk" and disabled=no' 0
    require_router_count "enabled regional WireGuard peer" '/interface wireguard peers print count-only where comment="regional-hk-owned" and disabled=no' 0
    ;;
  status)
    ssh "$router" '/system script run regional-hk-status'
    ;;
  *)
    echo "usage: $0 install|refresh-on|allowlist|on|off|status" >&2
    exit 2
    ;;
esac
