# Generated configuration is owned by this module. Everything starts disabled.
# Provisioner replaces only the two tokens in /run before an explicit operator import.
/interface wireguard add name=wg-regional-hk listen-port=51820 private-key="__HK_ROUTER_PRIVATE_KEY__" disabled=yes comment="regional-hk-owned"
/ip address add address=172.31.241.2/30 interface=wg-regional-hk disabled=yes comment="regional-hk-owned"
/interface wireguard peers add interface=wg-regional-hk public-key="__MICHIRU_PUBLIC_KEY__" endpoint-address=103.117.101.12 endpoint-port=51820 allowed-address=0.0.0.0/0 persistent-keepalive=25s disabled=yes comment="regional-hk-owned"
/routing table add name=hk-cn fib
/ip route add dst-address=0.0.0.0/0 gateway=wg-regional-hk routing-table=hk-cn distance=1 disabled=yes comment="regional-hk-owned"
/ip route add dst-address=0.0.0.0/0 blackhole routing-table=hk-cn distance=2 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=10.0.0.0/8 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=100.64.0.0/10 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=127.0.0.0/8 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=169.254.0.0/16 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=172.16.0.0/12 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=192.168.0.0/16 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=192.0.0.0/24 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=224.0.0.0/4 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=45.30.94.38 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=103.117.101.12 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=192.168.100.0/24 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-excluded address=172.31.241.0/30 disabled=yes comment="regional-hk-owned"
/ip firewall mangle add chain=regional-hk-cn-route src-address=__US_EXIT_SOURCE_IPV4__ action=return disabled=yes comment="regional-hk-owned"
/ip firewall mangle add chain=regional-hk-cn-route dst-address-list=regional-hk-excluded action=return disabled=yes comment="regional-hk-owned"
/ip firewall mangle add chain=regional-hk-cn-route dst-address-list=regional-hk-allowlist connection-state=new connection-nat-state=!dstnat connection-mark=no-mark action=mark-connection new-connection-mark=regional-hk-cn passthrough=yes disabled=yes comment="regional-hk-owned"
/ip firewall mangle add chain=regional-hk-cn-route connection-mark=regional-hk-cn connection-nat-state=!dstnat action=mark-routing new-routing-mark=hk-cn passthrough=no disabled=yes comment="regional-hk-owned"
/ip firewall mangle add chain=prerouting in-interface=bridge_lan src-address=192.168.88.0/24 action=jump jump-target=regional-hk-cn-route disabled=yes comment="regional-hk-owned"
/ip firewall nat add chain=srcnat src-address=192.168.88.0/24 out-interface=wg-regional-hk action=masquerade disabled=yes comment="regional-hk-owned"
/ip dns static add name="mado.moe" type=FWD forward-to=8.8.8.8 match-subdomain=yes address-list=regional-hk-excluded disabled=yes comment="regional-hk-owned"
/ip dns static add name="weixin.qq.com" type=FWD forward-to=8.8.8.8 match-subdomain=yes address-list=regional-hk-excluded disabled=yes comment="regional-hk-owned"
/ip firewall nat add chain=dstnat in-interface=bridge_lan src-address=192.168.88.0/24 dst-address-type=!local dst-address-list=!regional-hk-local-resolvers protocol=udp dst-port=53 action=redirect to-ports=53 disabled=yes comment="regional-hk-owned"
/ip firewall nat add chain=dstnat in-interface=bridge_lan src-address=192.168.88.0/24 dst-address-type=!local dst-address-list=!regional-hk-local-resolvers protocol=tcp dst-port=53 action=redirect to-ports=53 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-local-resolvers address=10.0.0.0/8 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-local-resolvers address=172.16.0.0/12 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-local-resolvers address=192.168.0.0/16 disabled=yes comment="regional-hk-owned"
/ip firewall address-list add list=regional-hk-local-resolvers address=100.64.0.0/10 disabled=yes comment="regional-hk-owned"

/system script add name=regional-hk-state comment="regional-hk-owned" policy=read,write,test source={
:global regionalHkFastTrackMark "__ORIGINAL_FASTTRACK_MARK__"
:global regionalHkDhcpDns "__ORIGINAL_DHCP_DNS__"
}
/system script add name=regional-hk-on comment="regional-hk-owned" policy=read,write,test source={
:local active [/interface wireguard get [find where name=wg-regional-hk] disabled]
:if ($active = false) do={ :put "regional HK routing already enabled"; :return }
/system script run regional-hk-state
:local fasttrack [/ip firewall filter find where comment="defconf: fasttrack" and action=fasttrack-connection]
:if ([:len $fasttrack] != 1) do={ :error "expected exactly one default fasttrack rule" }
:local dhcp [/ip dhcp-server network find where address="192.168.88.0/24"]
:if ([:len $dhcp] != 1) do={ :error "expected exactly one main-LAN DHCP network" }
/ip firewall filter set $fasttrack connection-mark=no-mark
/ip address enable [find where comment="regional-hk-owned"]
/interface wireguard enable [find where comment="regional-hk-owned"]
/interface wireguard peers enable [find where comment="regional-hk-owned"]
/ip route enable [find where comment="regional-hk-owned"]
/ip firewall address-list enable [find where comment="regional-hk-owned" and dynamic=no]
/ip dns static enable [find where comment="regional-hk-owned"]
/ip dhcp-server network set [find where address="192.168.88.0/24"] dns-server=192.168.88.1
/ip firewall nat enable [find where comment="regional-hk-owned"]
/ip firewall mangle enable [find where comment="regional-hk-owned"]
:delay 2s
/ip dns cache flush
:put "regional HK routing enabled; allowlisted destinations fail closed through wg-regional-hk"
}
/system script add name=regional-hk-off comment="regional-hk-owned" policy=read,write,test source={
/system script run regional-hk-state
/ip firewall mangle disable [find where comment="regional-hk-owned"]
:local regionalHkConnections [/ip firewall connection find where connection-mark=regional-hk-cn]
:foreach regionalHkConnection in=$regionalHkConnections do={ :do { /ip firewall connection remove $regionalHkConnection } on-error={} }
/ip firewall nat disable [find where comment="regional-hk-owned"]
/ip dns static disable [find where comment="regional-hk-owned"]
:global regionalHkDhcpDns
:local dhcp [/ip dhcp-server network find where address="192.168.88.0/24"]
:if ([:len $dhcp] = 1) do={ /ip dhcp-server network set $dhcp dns-server=$regionalHkDhcpDns }
/ip route disable [find where comment="regional-hk-owned"]
/ip firewall address-list disable [find where comment="regional-hk-owned" and dynamic=no]
/ip address disable [find where comment="regional-hk-owned"]
/interface wireguard peers disable [find where comment="regional-hk-owned"]
/interface wireguard disable [find where comment="regional-hk-owned"]
:local fasttrack [/ip firewall filter find where comment="defconf: fasttrack" and action=fasttrack-connection]
:global regionalHkFastTrackMark
:if ([:len $fasttrack] = 1) do={ :if ([:len $regionalHkFastTrackMark] = 0) do={ /ip firewall filter unset $fasttrack connection-mark } else={ /ip firewall filter set $fasttrack connection-mark=$regionalHkFastTrackMark } }
:put "regional HK routing disabled; marked connections removed; LAN defaults to US WAN"
}
/system script add name=regional-hk-status comment="regional-hk-owned" policy=read,test source={
/interface wireguard peers print detail where interface=wg-regional-hk
/ip route print detail where routing-table=hk-cn
/ip firewall connection print count-only where connection-mark=regional-hk-cn
:put "Inspect regional-hk-owned disabled flags and DNS dynamic address-list timeouts for full status."
}
