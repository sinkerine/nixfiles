# Split DNS: use LAN addresses at home; public DNS retains Tailscale A/AAAA.
# Exact records override upstream DNS without changing the base host records.
:foreach host in={"kazuki";"sachi"} do={
    :local recordName ("paeso." . $host . ".m.mado.moe")
    :local hostAddress "192.168.88.29"
    :if ($host = "sachi") do={ :set hostAddress "192.168.88.30" }
    :local existing [/ip dns static find where name=$recordName and type=A]
    :if ([:len $existing] = 0) do={
        /ip dns static add name=$recordName type=A address=$hostAddress ttl=1m comment=nixfiles-paseo-lan
    } else={
        :if ([:len $existing] != 1) do={ :error ("Multiple A records exist for " . $recordName) }
        :if ([/ip dns static get $existing address] != $hostAddress) do={ :error ("Conflicting A record exists for " . $recordName) }
    }
}
# Existing prefix sync generates matching LAN AAAA records for these A overrides.
/system script run native-ipv6-prefix-sync
/ip dns cache flush
/ip dns static print detail where name~"paeso"
