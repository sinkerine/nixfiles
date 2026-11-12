#!/usr/bin/env python3
"""Add IPv6 to an installed RouterOS regional-HK policy without reinstalling IPv4."""

import argparse
import subprocess
import sys

from allowlist import ssh

COMMENT = "regional-hk-ipv6-owned"
OWNED = f'[find where comment="{COMMENT}"]'


def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('\n', '\\n') + '"'


def objects():
    rows = [
        '/ipv6 address add address=fd31:241::2/64 interface=wg-regional-hk advertise=no',
        '/ipv6 route add dst-address=::/0 gateway=fd31:241::1%wg-regional-hk routing-table=hk-cn distance=1',
        '/ipv6 route add dst-address=::/0 blackhole routing-table=hk-cn distance=2',
    ]
    for network in ('::/128', '::1/128', 'fc00::/7', 'fe80::/10', 'ff00::/8', '2001:db8::/32'):
        rows.append(f'/ipv6 firewall address-list add list=regional-hk-excluded address={network}')
    for network in ('fc00::/7', 'fe80::/10', '::1/128'):
        rows.append(f'/ipv6 firewall address-list add list=regional-hk-local-resolvers address={network}')
    rows.extend([
        '/ipv6 firewall mangle add chain=regional-hk-cn-route dst-address-type=local action=return',
        '/ipv6 firewall mangle add chain=regional-hk-cn-route dst-address-list=regional-hk-excluded action=return',
        '/ipv6 firewall mangle add chain=regional-hk-cn-route dst-address-list=native-ipv6-main action=return',
        '/ipv6 firewall mangle add chain=regional-hk-cn-route dst-address-list=native-ipv6-guest action=return',
        '/ipv6 firewall mangle add chain=regional-hk-cn-route dst-address-list=regional-hk-allowlist connection-state=new connection-nat-state=!dstnat connection-mark=no-mark action=mark-connection new-connection-mark=regional-hk-cn passthrough=yes',
        '/ipv6 firewall mangle add chain=regional-hk-cn-route connection-mark=regional-hk-cn connection-nat-state=!dstnat action=mark-routing new-routing-mark=hk-cn passthrough=no',
        '/ipv6 firewall mangle add chain=prerouting in-interface=bridge_lan src-address-list=native-ipv6-main action=jump jump-target=regional-hk-cn-route',
        # Use a stable tunnel source, independent of the ISP delegated prefix.
        '/ipv6 firewall nat add chain=srcnat out-interface=wg-regional-hk src-address-list=native-ipv6-main action=src-nat to-address=fd31:241::2/128',
        '/ipv6 firewall filter add chain=forward in-interface=bridge_lan out-interface=wg-regional-hk src-address-list=native-ipv6-main connection-mark=regional-hk-cn action=accept place-before=[find where comment="native-ipv6-forward-drop"]',
    ])
    for protocol in ('udp', 'tcp'):
        rows.append('/ipv6 firewall nat add chain=dstnat in-interface=bridge_lan '
                    'src-address-list=native-ipv6-main dst-address-type=!local '
                    'dst-address-list=!regional-hk-local-resolvers '
                    f'protocol={protocol} dst-port=53 action=redirect to-ports=53')
    return [f'{row} disabled=yes comment="{COMMENT}"' for row in rows]


def on_source():
    # Enable marking last, after the path and the fail-closed route exist.
    return '\n'.join(f'{path} enable {OWNED}' for path in (
        '/ipv6 address', '/ipv6 route', '/ipv6 firewall address-list',
        '/ipv6 firewall filter', '/ipv6 firewall nat', '/ipv6 firewall mangle'))


def off_source():
    return '\n'.join([
        f'/ipv6 firewall mangle disable {OWNED}',
        ':foreach c in=[/ipv6 firewall connection find where connection-mark="regional-hk-cn"] do={ :do { /ipv6 firewall connection remove $c } on-error={} }',
        *[f'{path} disable {OWNED}' for path in (
            '/ipv6 firewall nat', '/ipv6 firewall filter', '/ipv6 route',
            '/ipv6 firewall address-list', '/ipv6 address')],
    ])


def hook(state):
    name = f'regional-hk-ipv6-{state}'
    return f':if ([:len [/system script find where name="{name}"]] = 1) do={{ /system script run {name} }}'


def require(target, command, expected):
    actual = ssh(target, command)
    if actual != str(expected):
        raise RuntimeError(f'IPv6 verification failed: {command}: expected {expected}, found {actual!r}')


def apply(target):
    for command, count in (
        ('/interface wireguard print count-only where name="wg-regional-hk"', 1),
        ('/interface wireguard peers print count-only where interface="wg-regional-hk"', 1),
        ('/routing table print count-only where name="hk-cn"', 1),
        ('/ipv6 firewall filter print count-only where comment="native-ipv6-forward-drop"', 1),
        ('/ipv6 firewall address-list print count-only where list="native-ipv6-main"', 1),
        ('/system script print count-only where name="regional-hk-on"', 1),
        ('/system script print count-only where name="regional-hk-off"', 1),
    ):
        require(target, command, count)
    sources = {state: ssh(target, f':put [/system script get [find where name="regional-hk-{state}"] source]')
               for state in ('on', 'off')}
    anchors = {
        'on': '/ip firewall mangle enable [find where comment="regional-hk-owned"]',
        'off': '/system script run regional-hk-state',
    }
    for state, source in sources.items():
        if not source or (f'/system script run regional-hk-ipv6-{state}' not in source
                          and source.count(anchors[state]) != 1):
            raise RuntimeError(f'unexpected {state} script; no configuration changed')
    active = ssh(target, ':put [/interface wireguard get [find where name="wg-regional-hk"] disabled]')
    if active not in ('true', 'false', 'yes', 'no'):
        raise RuntimeError('unexpected tunnel state; no configuration changed')
    enabled = active in ('false', 'no')
    # Reapplying removes only this extension's objects. IPv4 remains installed.
    ssh(target, off_source())
    for path in ('/ipv6 firewall mangle', '/ipv6 firewall nat', '/ipv6 firewall filter',
                 '/ipv6 route', '/ipv6 address', '/ipv6 firewall address-list'):
        ssh(target, f'{path} remove {OWNED}')
    ssh(target, '/interface wireguard peers set [find where interface="wg-regional-hk"] allowed-address=0.0.0.0/0,::/0')
    for row in objects():
        ssh(target, row)
    for state, source in (('on', on_source()), ('off', off_source())):
        name = f'regional-hk-ipv6-{state}'
        ssh(target, f':if ([:len [/system script find where name="{name}"]] = 0) do={{ /system script add name={name} comment="{COMMENT}" policy=read,write,test }}')
        ssh(target, f'/system script set [find where name="{name}"] source={quote(source)}')
    for state, source in sources.items():
        if f'/system script run regional-hk-ipv6-{state}' not in source:
            # ON: after IPv4 setup; OFF: before disabling the shared tunnel.
            source = source.replace(anchors[state], anchors[state] + '\n' + hook(state))
            ssh(target, f'/system script set [find where name="regional-hk-{state}"] source={quote(source)}')
        installed = ssh(target, f':put [/system script get [find where name="regional-hk-{state}"] source]')
        if f'/system script run regional-hk-ipv6-{state}' not in installed:
            raise RuntimeError(f'IPv6 {state} hook was not installed')
    for path, count in (('/ipv6 address', 1), ('/ipv6 route', 2),
                        ('/ipv6 firewall mangle', 7), ('/ipv6 firewall nat', 3),
                        ('/ipv6 firewall filter', 1), ('/ipv6 firewall address-list', 9)):
        require(target, f'{path} print count-only where comment="{COMMENT}"', count)
    if enabled:
        ssh(target, '/system script run regional-hk-ipv6-on')
    for path, count in (('/ipv6 address', 1), ('/ipv6 route', 2),
                        ('/ipv6 firewall mangle', 7), ('/ipv6 firewall nat', 3),
                        ('/ipv6 firewall filter', 1), ('/ipv6 firewall address-list', 9)):
        require(target, f'{path} print count-only where comment="{COMMENT}" and disabled=no', count if enabled else 0)
    ssh(target, '/ip dns cache flush')
    print(f"IPv6 regional HK policy installed and verified; proxy {'ON' if enabled else 'OFF'}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--router', default='router')
    args = parser.parse_args()
    try:
        apply(args.router)
    except (RuntimeError, OSError, subprocess.TimeoutExpired) as error:
        print(f'IPv6 provisioning failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
