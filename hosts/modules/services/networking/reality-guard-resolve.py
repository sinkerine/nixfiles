#!/usr/bin/env python3
"""Resolve REALITY decoy domains and atomically update inet reality_guard nft sets."""

import argparse
from contextlib import contextmanager
import fcntl
import ipaddress
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterator, List, Optional, Set, Tuple

DEFAULT_CACHE_FILE = "/var/lib/reality-guard/cache.json"
DEFAULT_LOCK_FILE = "/var/lib/reality-guard/lock"
DEFAULT_RETENTION_SECONDS = 1800
NFT_TABLE = "inet reality_guard"


def parse_args(argv: List[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve REALITY decoy domains and update nftables sets."
    )
    parser.add_argument(
        "--apply-cache-only",
        action="store_true",
        help="Restore cached IPs into nftables sets without performing DNS lookups.",
    )
    parser.add_argument(
        "--render-ruleset",
        metavar="RULES_FILE",
        help="Combine static nft rules file with cached set elements and apply as one transaction.",
    )
    parser.add_argument(
        "--nft-bin",
        default=os.environ.get("NFT_BIN", "nft"),
        help="Path to nft binary (default: $NFT_BIN or 'nft').",
    )
    parser.add_argument("config", help="Path to JSON configuration file.")
    return parser.parse_args(argv)


@contextmanager
def acquire_lock(lock_path: Path) -> Iterator[None]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o640)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def resolve_lock_path(config: dict, cache_path: Path) -> Path:
    configured = config.get("lockFile")
    if configured:
        return Path(configured)
    return cache_path.with_suffix(".lock")


def parse_bare_ip(raw_ip: object, expected_version: int) -> Optional[str]:
    if not isinstance(raw_ip, str) or "%" in raw_ip:
        return None
    try:
        ip_obj = ipaddress.ip_address(raw_ip)
    except ValueError:
        return None
    if ip_obj.version != expected_version or getattr(ip_obj, "scope_id", None) is not None:
        return None
    return str(ip_obj)


def load_cache(cache_path: Path) -> Dict[str, Dict[str, Dict[str, float]]]:
    if not cache_path.exists():
        return {}
    try:
        raw = json.loads(cache_path.read_text(encoding="utf-8"))
        if not isinstance(raw, dict):
            raise ValueError("cache root must be a JSON object")
    except Exception as exc:
        print(f"warning: failed to read cache {cache_path}: {exc}", file=sys.stderr)
        return {}

    cleaned: Dict[str, Dict[str, Dict[str, float]]] = {}
    for domain, entry in raw.items():
        if not isinstance(domain, str) or not isinstance(entry, dict):
            print(
                f"warning: discarding malformed cache record for {domain!r}",
                file=sys.stderr,
            )
            continue
        clean_entry: Dict[str, Dict[str, float]] = {"v4": {}, "v6": {}}
        for fam_key, version in (("v4", 4), ("v6", 6)):
            fam_map = entry.get(fam_key)
            if fam_map is None:
                continue
            if not isinstance(fam_map, dict):
                print(
                    f"warning: discarding malformed {fam_key} map for {domain!r}",
                    file=sys.stderr,
                )
                continue
            for raw_ip, ts in fam_map.items():
                bare = parse_bare_ip(raw_ip, version)
                if bare is None or not isinstance(ts, (int, float)) or isinstance(ts, bool):
                    print(
                        f"warning: discarding invalid {fam_key} entry {raw_ip!r} for {domain!r}",
                        file=sys.stderr,
                    )
                    continue
                clean_entry[fam_key][bare] = float(ts)
        cleaned[domain] = clean_entry
    return cleaned


def save_cache(cache_path: Path, cache: Dict[str, Dict[str, Dict[str, float]]]) -> None:
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=".cache-", suffix=".json", dir=str(cache_path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(cache, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp_name, cache_path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def resolve_domain(domain: str) -> Tuple[Set[str], Set[str]]:
    v4: Set[str] = set()
    v6: Set[str] = set()
    infos = socket.getaddrinfo(domain, 443, socket.AF_UNSPEC, socket.SOCK_STREAM)
    for _family, _socktype, _proto, _canonname, sockaddr in infos:
        addr_str = sockaddr[0].split("%", 1)[0]
        ip_obj = ipaddress.ip_address(addr_str)
        if ip_obj.version == 4:
            v4.add(str(ip_obj))
        elif ip_obj.version == 6:
            v6.add(str(ip_obj))
    if not v4 and not v6:
        raise socket.gaierror(f"empty address list for {domain}")
    return v4, v6


def merge_domain_cache(
    prev_entry: Dict[str, Dict[str, float]] | None,
    fresh_v4: Set[str],
    fresh_v6: Set[str],
    now: float,
    retention: float,
) -> Dict[str, Dict[str, float]]:
    prev_v4 = (prev_entry or {}).get("v4", {})
    prev_v6 = (prev_entry or {}).get("v6", {})

    next_v4: Dict[str, float] = {
        ip: ts for ip, ts in prev_v4.items() if (now - float(ts)) <= retention
    }
    next_v6: Dict[str, float] = {
        ip: ts for ip, ts in prev_v6.items() if (now - float(ts)) <= retention
    }

    for ip in fresh_v4:
        next_v4[ip] = now
    for ip in fresh_v6:
        next_v6[ip] = now

    return {"v4": next_v4, "v6": next_v6}


def collect_ips_for_domains(
    domains: List[str], cache: Dict[str, Dict[str, Dict[str, float]]]
) -> Tuple[List[str], List[str]]:
    v4: Set[str] = set()
    v6: Set[str] = set()
    for domain in domains:
        entry = cache.get(domain)
        if not isinstance(entry, dict):
            continue
        v4_map = entry.get("v4")
        if isinstance(v4_map, dict):
            for raw_ip in v4_map.keys():
                bare = parse_bare_ip(raw_ip, 4)
                if bare is not None:
                    v4.add(bare)
        v6_map = entry.get("v6")
        if isinstance(v6_map, dict):
            for raw_ip in v6_map.keys():
                bare = parse_bare_ip(raw_ip, 6)
                if bare is not None:
                    v6.add(bare)
    return sorted(v4), sorted(v6)


def build_nft_commands(
    strict_v4: List[str],
    strict_v6: List[str],
    relaxed_v4: List[str],
    relaxed_v6: List[str],
    *,
    flush: bool = True,
) -> str:
    lines: List[str] = []
    sets = [
        ("decoy_strict_v4", strict_v4),
        ("decoy_strict_v6", strict_v6),
        ("decoy_relaxed_v4", relaxed_v4),
        ("decoy_relaxed_v6", relaxed_v6),
    ]
    for set_name, ips in sets:
        if flush:
            lines.append(f"flush set {NFT_TABLE} {set_name}")
        if ips:
            joined = ", ".join(ips)
            lines.append(f"add element {NFT_TABLE} {set_name} {{ {joined} }}")
    return ("\n".join(lines) + "\n") if lines else ""


def apply_nft(nft_bin: str, commands: str) -> int:
    proc = subprocess.run(
        [nft_bin, "-f", "-"],
        input=commands,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        err = proc.stderr.strip() or proc.stdout.strip() or f"exit code {proc.returncode}"
        print(f"error: nft -f - failed: {err}", file=sys.stderr)
        return proc.returncode
    return 0


def main(argv: List[str] | None = None) -> int:
    args = parse_args(argv)
    config = json.loads(Path(args.config).read_text(encoding="utf-8"))
    strict_domains: List[str] = list(dict.fromkeys(config.get("strictDomains", [])))
    relaxed_domains: List[str] = list(dict.fromkeys(config.get("relaxedDomains", [])))
    retention = float(config.get("ipRetentionSeconds", DEFAULT_RETENTION_SECONDS))
    cache_path = Path(config.get("cacheFile", DEFAULT_CACHE_FILE))
    lock_path = resolve_lock_path(config, cache_path)
    all_domains = list(dict.fromkeys(strict_domains + relaxed_domains))

    if args.render_ruleset:
        rules_text = Path(args.render_ruleset).read_text(encoding="utf-8")
        with acquire_lock(lock_path):
            cache = load_cache(cache_path)
            strict_v4, strict_v6 = collect_ips_for_domains(strict_domains, cache)
            relaxed_v4, relaxed_v6 = collect_ips_for_domains(relaxed_domains, cache)
            elements = build_nft_commands(
                strict_v4, strict_v6, relaxed_v4, relaxed_v6, flush=False
            )
            script = rules_text.rstrip("\n") + "\n" + elements
            return apply_nft(args.nft_bin, script)

    if args.apply_cache_only:
        with acquire_lock(lock_path):
            cache = load_cache(cache_path)
            if not cache:
                return 0
            strict_v4, strict_v6 = collect_ips_for_domains(strict_domains, cache)
            relaxed_v4, relaxed_v6 = collect_ips_for_domains(relaxed_domains, cache)
            if not (strict_v4 or strict_v6 or relaxed_v4 or relaxed_v6):
                return 0
            commands = build_nft_commands(strict_v4, strict_v6, relaxed_v4, relaxed_v6)
            return apply_nft(args.nft_bin, commands)

    # Perform DNS lookups outside the lock so slow/timed-out queries never block start/reload.
    resolved: Dict[str, Optional[Tuple[Set[str], Set[str]]]] = {}
    for domain in all_domains:
        try:
            resolved[domain] = resolve_domain(domain)
        except Exception as exc:
            print(
                f"warning: DNS resolution failed for {domain}: {exc}; preserving cached IPs",
                file=sys.stderr,
            )
            resolved[domain] = None

    with acquire_lock(lock_path):
        now = time.time()
        cache = load_cache(cache_path)
        next_cache: Dict[str, Dict[str, Dict[str, float]]] = {}
        for domain in all_domains:
            prev_entry = cache.get(domain)
            fresh = resolved[domain]
            if fresh is not None:
                next_cache[domain] = merge_domain_cache(
                    prev_entry, fresh[0], fresh[1], now, retention
                )
            elif prev_entry is not None:
                next_cache[domain] = prev_entry
            else:
                next_cache[domain] = {"v4": {}, "v6": {}}

        save_cache(cache_path, next_cache)
        strict_v4, strict_v6 = collect_ips_for_domains(strict_domains, next_cache)
        relaxed_v4, relaxed_v6 = collect_ips_for_domains(relaxed_domains, next_cache)
        commands = build_nft_commands(strict_v4, strict_v6, relaxed_v4, relaxed_v6)
        return apply_nft(args.nft_bin, commands)


if __name__ == "__main__":
    sys.exit(main())
