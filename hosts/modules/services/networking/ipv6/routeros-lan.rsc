{
:local pool [/ipv6 pool find where name="native-ipv6-pd"]
:if ([:len $pool] != 1) do={ :error "No delegated IPv6 pool; LAN activation refused" }
:local prefix [:tostr [/ipv6 pool get $pool prefix]]
:local length [:tonum [:pick $prefix ([:find $prefix "/"] + 1) [:len $prefix]]]
:if ($length > 63) do={ :error "Delegation must provide at least two /64s; LAN activation refused" }
:foreach iface in={"bridge_lan";"bridge_vlan2"} do={
    :if ([:len [/ipv6 address find where interface=$iface and from-pool="native-ipv6-pd"]] = 0) do={
        /ipv6 address add interface=$iface address=::1/64 from-pool=native-ipv6-pd advertise=yes comment=native-ipv6-lan
    }
}
/system script run native-ipv6-prefix-sync
}
