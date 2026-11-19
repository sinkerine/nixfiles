#!/usr/bin/env python3
"""Resolve shared workload profiles into explicit qex claims, without a shell."""
import argparse
from decimal import Decimal
import json
import os
from pathlib import Path
import re
import subprocess
import sys


PROFILE_PATH = Path(os.environ.get("AGENT_JOB_PROFILES", Path(__file__).with_name("profiles.json")))
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z")
E2E_BLOCK = re.compile(r"^```qex-e2e[ \t]+([A-Za-z0-9][A-Za-z0-9_.-]{0,79})[ \t]*\n(.*?)^```[ \t]*(?:\n|$)", re.MULTILINE | re.DOTALL)
MEMORY = re.compile(r"([0-9]+(?:\.[0-9]+)?|\.[0-9]+)[ \t]*(B|[KMGT]i?B|[KMGT])", re.IGNORECASE)
DURATION = re.compile(r"[0-9]+(?:\.[0-9]+)?(?:s|m|h|d)?")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_e2e_estimates(text):
    """Read qex job-file resource defaults from named Markdown fences."""
    entries = {}
    blocks = list(E2E_BLOCK.finditer(text))
    if not blocks or len(blocks) != len(re.findall(r"^```qex-e2e\b", text, re.MULTILINE)):
        raise ValueError("AGENTS.md needs well-formed ```qex-e2e <name> JSON blocks")
    for block in blocks:
        name = block[1]
        if name in entries:
            raise ValueError(f"duplicate qex-e2e declaration: {name}")
        try:
            entry = json.loads(block[2], object_pairs_hook=reject_duplicate_keys)
        except ValueError as error:
            raise ValueError(f"{name}: invalid JSON: {error}") from error
        if not isinstance(entry, dict) or set(entry) - {"resources", "timeout", "locks"}:
            raise ValueError(f"{name}: allowed fields are resources, timeout and locks")
        resources = entry.get("resources")
        if not isinstance(resources, dict) or set(resources) - {"cpu", "mem", "claims"}:
            raise ValueError(f"{name}: resources must contain only cpu and mem; use locks for exclusive access")
        if "claims" in resources:
            # Existing Paseo declarations still carry the retired host I/O token.
            claims = resources.pop("claims")
            if not isinstance(claims, dict) or set(claims) != {"heavy-io"} or type(claims["heavy-io"]) is not int or claims["heavy-io"] != 1:
                raise ValueError(f"{name}: only cpu and mem are budgeted; use locks for exclusive access")
        cpu, mem = resources.get("cpu"), resources.get("mem")
        if type(cpu) is not int or cpu < 1:
            raise ValueError(f"{name}: resources.cpu must be a positive integer")
        size = MEMORY.fullmatch(mem) if isinstance(mem, str) else None
        if size is not None:
            exponent = "BKMGT".index(size[2][0].upper())
            byte_count = Decimal(size[1]) * (1024 ** exponent)
        if size is None or not 1 <= byte_count <= 2 ** 64 - 1:
            raise ValueError(f"{name}: resources.mem must be a positive explicit byte size, e.g. 16GiB")
        locks = entry.get("locks", [])
        if not isinstance(locks, list) or any(not isinstance(lock, str) or not NAME.fullmatch(lock) for lock in locks) or len(set(locks)) != len(locks):
            raise ValueError(f"{name}: locks must be distinct safe names")
        timeout = entry.get("timeout")
        if timeout is not None and (not isinstance(timeout, str) or not DURATION.fullmatch(timeout)):
            raise ValueError(f"{name}: timeout must be a duration such as 15m")
        entries[name] = entry
    return entries


def repository_estimates(cwd):
    try:
        result = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--show-toplevel"],
                                capture_output=True, text=True, check=True)
        agents = Path(result.stdout.strip()) / "AGENTS.md"
        return agents, parse_e2e_estimates(agents.read_text())
    except (OSError, subprocess.CalledProcessError) as error:
        raise ValueError(f"cannot read root AGENTS.md E2E estimates from {cwd}: {error}") from error


def resolve(argv, *, qex, profiles, environ):
    """Return an executable argv, or profile information; do not submit work."""
    arguments = list(argv)
    if "--" in arguments:
        boundary = arguments.index("--")
        options, command = arguments[:boundary], arguments[boundary + 1:]
    else:
        options, command = arguments, []

    parser = argparse.ArgumentParser(
        description="Submit Gradle builds or E2E tests to the shared host qex scheduler using explicit resource estimates."
    )
    actions = parser.add_subparsers(dest="action", required=True)
    listing = actions.add_parser("profiles", help="Show the centrally configured resource estimates")
    listing.add_argument("--json", action="store_true")
    estimates = actions.add_parser("estimates", help="Validate and list the root AGENTS.md E2E resource declarations")
    estimates.add_argument("--cwd", type=Path, default=Path.cwd())
    for action in ("submit", "run"):
        sub = actions.add_parser(action, help="Return a job ID" if action == "submit" else "Wait, stream output, and propagate the job exit code")
        sub.add_argument("profile", choices=profiles, nargs="?")
        sub.add_argument("--e2e", metavar="NAME", help="Use the named root AGENTS.md E2E declaration instead of a global profile")
        sub.add_argument("--cwd", type=Path, default=Path.cwd())
        sub.add_argument("--timeout", help="Execution timeout, e.g. 10m; queue wait is separate")
        sub.add_argument("--id-file", type=Path, help="Save the job ID for resume and cancellation")
        sub.add_argument("--name")
        sub.add_argument("--lock", action="append", default=[], help="Additional qex lock; repeat as needed")
        sub.add_argument("--dry-run", action="store_true", help="Show resolved argv without submitting")
    args = parser.parse_args(options)
    if args.action in ("profiles", "estimates"):
        if command:
            parser.error(f"{args.action} does not execute a command")
        if args.action == "estimates":
            try:
                agents, args.estimates = repository_estimates(args.cwd.resolve())
                args.agents = str(agents)
            except ValueError as error:
                parser.error(str(error))
        return args, None
    if bool(args.profile) == bool(args.e2e):
        parser.error("choose either a global profile or --e2e NAME")
    if not command:
        parser.error("provide an executable and arguments after --")
    if environ.get("AGENT_JOB_ACTIVE") == "1":
        parser.error("already inside a queued job; run only covered descendants directly, or submit a separate workload from outside that job")
    cwd = args.cwd.resolve()
    if not cwd.is_dir():
        parser.error(f"working directory does not exist: {cwd}")
    if args.id_file:
        args.id_file = args.id_file.absolute()
        if not args.id_file.parent.is_dir():
            parser.error(f"ID file parent does not exist: {args.id_file.parent}")
    declaration = {}
    if args.e2e:
        try:
            agents, entries = repository_estimates(cwd)
            if args.e2e not in entries:
                raise ValueError(f"{agents}: no qex-e2e declaration named {args.e2e!r}")
            declaration = entries[args.e2e]
        except ValueError as error:
            parser.error(str(error))
        profile, tag = declaration["resources"], f"e2e:{args.e2e}"
    else:
        profile, tag = profiles[args.profile], f"profile:{args.profile}"
    resolved = [qex, args.action, "--cpu", str(profile["cpu"]), "--mem", profile["mem"],
                "--cwd", str(cwd), "--tag", tag, "--env", "AGENT_JOB_ACTIVE=1"]
    for option, value in (("--timeout", args.timeout or declaration.get("timeout")), ("--id-file", args.id_file), ("--name", args.name)):
        if value is not None:
            resolved.extend([option, str(value)])
    for lock in dict.fromkeys([*declaration.get("locks", []), *args.lock]):
        resolved.extend(["--lock", lock])
    resolved.extend(["--", *command])
    return args, resolved


def main():
    profiles = json.loads(PROFILE_PATH.read_text())
    qex = os.environ["AGENT_JOB_QEX"]
    args, resolved = resolve(sys.argv[1:], qex=qex, profiles=profiles, environ=os.environ)
    if args.action == "profiles":
        if args.json:
            print(json.dumps(profiles, indent=2))
        else:
            for name, profile in profiles.items():
                print(f"{name:14} cpu={profile['cpu']} mem={profile['mem']:6}  {profile['description']}")
        return
    if args.action == "estimates":
        print(json.dumps({"source": args.agents, "estimates": args.estimates}, indent=2))
        return
    if args.dry_run:
        print(json.dumps(resolved, indent=2))
        return
    os.execv(qex, resolved)


if __name__ == "__main__":
    main()
