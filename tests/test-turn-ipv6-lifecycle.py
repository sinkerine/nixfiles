import ipaddress


def stable(rows):
    out = []
    for row in rows:
        if row.get("scope") != "global" or row.get("valid_life_time", 1) == 0 or row.get("preferred_life_time", 1) == 0:
            continue
        if any(row.get(k) for k in ("temporary", "tentative", "deprecated", "dadfailed")):
            continue
        addr = ipaddress.IPv6Address(row["local"])
        if addr.is_private or addr.is_link_local or addr.is_loopback or addr.is_unspecified:
            continue
        out.append(str(addr))
    return sorted(set(out))


def owned(records, marker="nixfiles-michiru-turn-ipv6"):
    exact = [r for r in records if (r.get("comment") or "") == marker]
    unmanaged = [r for r in records if r not in exact]
    if unmanaged or len(exact) > 1:
        raise ValueError("unmanaged or duplicate AAAA")
    return exact


def test_stable_filters_lifetime_flags_and_accepts_non_64_prefix():
    rows = [
        {"local": "2403:18c0:4:3cb::1", "scope": "global", "prefixlen": 56, "valid_life_time": 10, "preferred_life_time": 10},
        {"local": "2403:18c0:4:3cb::2", "scope": "global", "valid_life_time": 0, "preferred_life_time": 10},
        {"local": "2403:18c0:4:3cb::3", "scope": "global", "valid_life_time": 10, "preferred_life_time": 0},
        {"local": "2403:18c0:4:3cb::4", "scope": "global", "temporary": True},
    ]
    assert stable(rows) == ["2403:18c0:4:3cb::1"]


def test_dns_ownership_requires_exact_single_marker():
    record = {"comment": "nixfiles-michiru-turn-ipv6", "content": "2001:db8::1"}
    assert owned([record]) == [record]
    try:
        owned([record, {"comment": "nixfiles-michiru-turn-ipv6", "content": "2001:db8::2"}])
        assert False
    except ValueError:
        pass
    try:
        owned([{"comment": "nixfiles-michiru-turn-ipv6-old", "content": "2001:db8::1"}])
        assert False
    except ValueError:
        pass
