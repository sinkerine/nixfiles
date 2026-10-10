# Native dual stack. This importer owns only native-ipv6-* objects.
# Apply firewall before enabling IPv6. No IPv4 objects are changed.
:if ([:len [/ipv6 firewall filter find where comment="native-ipv6-input-established"]] > 0) do={ :error "native IPv6 already installed; inspect before retry" }
/ipv6 firewall filter add chain=input action=accept connection-state=established,related comment=native-ipv6-input-established
/ipv6 firewall filter add chain=input action=drop connection-state=invalid comment=native-ipv6-input-invalid
/ipv6 firewall filter add chain=input action=accept protocol=icmpv6 comment=native-ipv6-input-icmp
/ipv6 firewall filter add chain=input action=accept in-interface=sfp-sfpplus1 protocol=udp src-address=fe80::/10 src-port=547 dst-port=546 comment=native-ipv6-input-dhcp
/ipv6 firewall filter add chain=input action=accept in-interface=bridge_vlan2 protocol=udp dst-port=53 comment=native-ipv6-guest-dns-udp
/ipv6 firewall filter add chain=input action=accept in-interface=bridge_vlan2 protocol=tcp dst-port=53 comment=native-ipv6-guest-dns-tcp
/ipv6 firewall filter add chain=input action=drop in-interface=bridge_vlan2 comment=native-ipv6-guest-management
/ipv6 firewall filter add chain=input action=accept in-interface=bridge_lan comment=native-ipv6-input-lan
/ipv6 firewall filter add chain=input action=drop comment=native-ipv6-input-drop
/ipv6 firewall filter add chain=forward action=drop in-interface=bridge_vlan2 out-interface=bridge_lan comment=native-ipv6-guest-isolation
/ipv6 firewall filter add chain=forward action=drop in-interface=bridge_lan out-interface=bridge_vlan2 comment=native-ipv6-main-isolation
/ipv6 firewall filter add chain=forward action=accept connection-state=established,related comment=native-ipv6-forward-established
/ipv6 firewall filter add chain=forward action=drop connection-state=invalid comment=native-ipv6-forward-invalid
/ipv6 firewall filter add chain=forward action=accept protocol=icmpv6 icmp-options=1:0-255 comment=native-ipv6-forward-unreachable
/ipv6 firewall filter add chain=forward action=accept protocol=icmpv6 icmp-options=2:0-255 comment=native-ipv6-forward-pmtu
/ipv6 firewall filter add chain=forward action=accept protocol=icmpv6 icmp-options=3:0-255 comment=native-ipv6-forward-time
/ipv6 firewall filter add chain=forward action=accept protocol=icmpv6 icmp-options=4:0-255 comment=native-ipv6-forward-parameter
/ipv6 firewall filter add chain=forward action=accept in-interface=sfp-sfpplus1 dst-address-list=native-ipv6-sachi protocol=tcp dst-port=80,443 comment=native-ipv6-forward-web
/ipv6 firewall filter add chain=forward action=accept in-interface=bridge_lan out-interface=sfp-sfpplus1 src-address-list=native-ipv6-main comment=native-ipv6-forward-main
/ipv6 firewall filter add chain=forward action=accept in-interface=bridge_vlan2 out-interface=sfp-sfpplus1 src-address-list=native-ipv6-guest comment=native-ipv6-forward-guest
/ipv6 firewall filter add chain=forward action=drop comment=native-ipv6-forward-drop

/system script add name=native-ipv6-prefix-sync policy=read,write,test source={
    :local mask [:toip6 "ffff:ffff:ffff:ffff::"]
    :foreach iface in={"bridge_lan";"bridge_vlan2"} do={
        :local listName "native-ipv6-main"
        :if ($iface = "bridge_vlan2") do={ :set listName "native-ipv6-guest" }
        :local found false
        :foreach id in=[/ipv6 address find where interface=$iface and from-pool="native-ipv6-pd" and invalid=no] do={
            :local cidr [:tostr [/ipv6 address get $id address]]
            :local ip [:toip6 [:pick $cidr 0 [:find $cidr "/"]]]
            :local prefix ($ip & $mask)
            :local subnet ([:tostr $prefix] . "/64")
            :local old [/ipv6 firewall address-list find where list=$listName]
            :if ([:len $old] = 0) do={ /ipv6 firewall address-list add list=$listName address=$subnet comment=native-ipv6-prefix } else={ /ipv6 firewall address-list set $old address=$subnet }
            :if ($iface = "bridge_lan") do={
                :local sachi [:tostr ($prefix | [:toip6 "::30"])]
                :local web [/ipv6 firewall address-list find where list="native-ipv6-sachi"]
                :if ([:len $web] = 0) do={ /ipv6 firewall address-list add list=native-ipv6-sachi address=$sachi comment=native-ipv6-prefix } else={ /ipv6 firewall address-list set $web address=$sachi }
                :foreach recordId in=[/ip dns static find where type=A and disabled=no] do={
                    :local oldAddress [:tostr [/ip dns static get $recordId address]]
                    :local hostAddress ""
                    :if ($oldAddress = "192.168.88.1") do={ :set hostAddress [:tostr ($prefix | [:toip6 "::1"])] }
                    :if ($oldAddress = "192.168.88.29") do={ :set hostAddress [:tostr ($prefix | [:toip6 "::29"])] }
                    :if ($oldAddress = "192.168.88.30") do={ :set hostAddress $sachi }
                    :if ($hostAddress != "") do={
                        :local tag ("native-ipv6-dns-" . $recordId)
                        :local recordName [:tostr [/ip dns static get $recordId name]]
                        :local recordPattern [:tostr [/ip dns static get $recordId regexp]]
                        :local existingDns [/ip dns static find where comment=$tag]
                        :if ([:len $existingDns] = 0) do={
                            :if ($recordPattern != "") do={ /ip dns static add regexp=$recordPattern type=AAAA address=$hostAddress ttl=1m comment=$tag } else={ /ip dns static add name=$recordName type=AAAA address=$hostAddress ttl=1m comment=$tag }
                        } else={ /ip dns static set $existingDns address=$hostAddress }
                    }
                }
            }
            :set found true
        }
        :if (!$found) do={
            /ipv6 firewall address-list remove [find where list=$listName]
            :if ($iface = "bridge_lan") do={
                /ipv6 firewall address-list remove [find where list="native-ipv6-sachi"]
                /ip dns static remove [find where comment~"native-ipv6-dns-"]
            }
        }
    }
}
/system scheduler add name=native-ipv6-prefix-sync interval=1m on-event=native-ipv6-prefix-sync policy=read,write,test
/ipv6 nd set [find where default=yes] disabled=yes
/ipv6 nd add interface=bridge_lan ra-interval=20s-1m ra-lifetime=3m advertise-dns=yes dns=fe80::1afd:74ff:fec1:a3b managed-address-configuration=no other-configuration=no comment=native-ipv6-main
/ipv6 nd add interface=bridge_vlan2 ra-interval=20s-1m ra-lifetime=3m advertise-dns=yes dns=fe80::18fd:74ff:fec1:a45 managed-address-configuration=no other-configuration=no comment=native-ipv6-guest
/ipv6 settings set disable-ipv6=no forward=yes accept-router-advertisements=yes accept-router-advertisements-on=WAN
/ipv6 dhcp-client add interface=sfp-sfpplus1 request=prefix pool-name=native-ipv6-pd pool-prefix-length=64 prefix-hint=::/60 use-peer-dns=no add-default-route=no comment=native-ipv6-wan script={ :delay 2s; /system script run native-ipv6-prefix-sync }
# Addresses are added after the delegated pool is verified to contain two /64s.
:put "Native IPv6 WAN enabled; verify delegation before adding LAN pool addresses."
