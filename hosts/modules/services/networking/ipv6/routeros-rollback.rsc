# Remove only native IPv6 additions. Baseline IPv6 was disabled.
/system scheduler remove [find where name="native-ipv6-prefix-sync"]
/ipv6 dhcp-client remove [find where comment="native-ipv6-wan"]
/ipv6 address remove [find where comment="native-ipv6-lan"]
/ipv6 nd remove [find where interface="bridge_lan"]
/ipv6 nd remove [find where interface="bridge_vlan2"]
/ipv6 nd set [find where default=yes] disabled=no
/ipv6 firewall filter remove [find where comment~"native-ipv6-"]
/ipv6 firewall address-list remove [find where comment="native-ipv6-prefix"]
/ip dns static remove [find where comment~"native-ipv6-dns-"]
/system script remove [find where name="native-ipv6-prefix-sync"]
/ipv6 settings set disable-ipv6=yes accept-router-advertisements=no
