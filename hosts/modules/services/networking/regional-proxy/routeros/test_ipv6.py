from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).parent
sys.path.insert(0, str(ROOT))
import ipv6
import allowlist


class IPv6Tests(unittest.TestCase):
    def router(self, enabled=True, fail=None):
        self.commands = []
        self.sources = {
            'on': '/ip firewall mangle enable [find where comment="regional-hk-owned"]\n:put "on"',
            'off': '/system script run regional-hk-state\n/interface wireguard disable [find where comment="regional-hk-owned"]',
        }
        self.enabled = enabled

        def run(target, command):
            self.commands.append(command)
            if fail and fail in command:
                raise RuntimeError('injected router failure')
            if command.startswith(':put [/interface wireguard get'):
                return 'false' if self.enabled else 'true'
            if command.startswith('/system script set [find where name="regional-hk-on"]') or command.startswith('/system script set [find where name="regional-hk-off"]'):
                state = 'on' if 'regional-hk-on' in command else 'off'
                self.sources[state] = command.partition(' source=')[2]
            if 'source]' in command and command.startswith(':put'):
                state = 'on' if 'regional-hk-on' in command else 'off'
                return self.sources[state]
            if 'print count-only' in command:
                if 'regional-hk-ipv6-owned' not in command:
                    return '1'
                if 'disabled=no' in command and not self.enabled:
                    return '0'
                for path, count in (('/ipv6 address', 1), ('/ipv6 route', 2),
                                    ('/ipv6 firewall mangle', 7), ('/ipv6 firewall nat', 3),
                                    ('/ipv6 firewall filter', 1), ('/ipv6 firewall address-list', 9)):
                    if command.startswith(path + ' '):
                        return str(count)
            return ''
        return run

    def test_active_upgrade_preserves_ipv4_and_enables_ipv6_after_verification(self):
        with patch.object(ipv6, 'ssh', side_effect=self.router()):
            ipv6.apply('test-router')
        activate = self.commands.index('/system script run regional-hk-ipv6-on')
        verify = next(i for i, c in enumerate(self.commands) if c.startswith('/ipv6 route print count-only where comment='))
        self.assertGreater(activate, verify)
        self.assertFalse(any(c.startswith('/ip firewall') for c in self.commands))
        self.assertTrue(any('allowed-address=0.0.0.0/0,::/0' in c for c in self.commands))
        self.assertTrue(any('regional-hk-off' in c and 'regional-hk-ipv6-off' in c for c in self.commands))

    def test_disabled_proxy_stays_disabled(self):
        with patch.object(ipv6, 'ssh', side_effect=self.router(enabled=False)):
            ipv6.apply('test-router')
        self.assertNotIn('/system script run regional-hk-ipv6-on', self.commands)
        self.assertTrue(all('disabled=yes' in row for row in ipv6.objects()))

    def test_failure_does_not_enable_partial_configuration(self):
        with patch.object(ipv6, 'ssh', side_effect=self.router(fail='/ipv6 route add')):
            with self.assertRaises(RuntimeError):
                ipv6.apply('test-router')
        self.assertNotIn('/system script run regional-hk-ipv6-on', self.commands)

    def test_unexpected_toggle_source_is_rejected_before_mutation(self):
        run = self.router()
        self.sources['off'] = ':put "custom off script"'
        with patch.object(ipv6, 'ssh', side_effect=run):
            with self.assertRaisesRegex(RuntimeError, 'no configuration changed'):
                ipv6.apply('test-router')
        self.assertFalse(any(' add ' in c or ' remove ' in c or ' disable ' in c for c in self.commands))

    def test_existing_hooks_are_not_duplicated(self):
        run = self.router()
        for state in self.sources:
            self.sources[state] += '\n' + ipv6.hook(state)
        with patch.object(ipv6, 'ssh', side_effect=run):
            ipv6.apply('test-router')
        self.assertFalse(any(c.startswith('/system script set [find where name="regional-hk-on"]') for c in self.commands))

    def test_policy_excludes_guest_and_local_networks_and_fails_closed(self):
        rows = ipv6.objects()
        jumps = [row for row in rows if 'action=jump' in row]
        self.assertEqual(len(jumps), 1)
        self.assertIn('in-interface=bridge_lan src-address-list=native-ipv6-main', jumps[0])
        self.assertTrue(any('dst-address=::/0 blackhole' in row for row in rows))
        exclusions = [row for row in rows if 'action=return' in row]
        self.assertTrue(any('dst-address-list=native-ipv6-main' in row for row in exclusions))
        self.assertTrue(any('dst-address-list=native-ipv6-guest' in row for row in exclusions))
        self.assertIn('connection-mark="regional-hk-cn"', ipv6.off_source())
        self.assertNotIn('/ip firewall connection', ipv6.off_source())

    def test_allowlist_refresh_clears_both_families_and_restores_classification(self):
        commands = []
        def run(target, command):
            commands.append(command)
            if 'address-list-extra-time' in command:
                return '0s'
            if 'disabled]' in command:
                return 'false'
            if 'print count-only' in command:
                return '0' if 'address-list print count-only where list="regional-hk-cn"' in command else '1'
            return ''
        with patch.object(allowlist, 'ssh', side_effect=run):
            allowlist.apply(['amap.com'], 'test-router')
        self.assertTrue(any('/ipv6 firewall connection remove' in c for c in commands))
        self.assertTrue(any('/ipv6 firewall address-list remove' in c for c in commands))
        disable = next(i for i, c in enumerate(commands) if c.startswith('/ipv6 firewall mangle disable'))
        clear = next(i for i, c in enumerate(commands) if c.startswith('/ipv6 firewall address-list remove'))
        enable = next(i for i, c in enumerate(commands) if c.startswith('/ipv6 firewall mangle enable'))
        self.assertLess(disable, clear)
        self.assertLess(clear, enable)


if __name__ == '__main__':
    unittest.main()
