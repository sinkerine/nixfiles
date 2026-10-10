#!/usr/bin/env python3
import json
import pathlib
import sys


def replace_markers(value, credentials):
    if isinstance(value, dict):
        return {key: replace_markers(item, credentials) for key, item in value.items()}
    if isinstance(value, list):
        return [replace_markers(item, credentials) for item in value]
    if isinstance(value, str) and value.startswith("@") and value.endswith("@"):
        marker = value[1:-1]
        if marker in credentials:
            return credentials[marker]
    return value


def main():
    template_path, output_path, credential_dir = map(pathlib.Path, sys.argv[1:4])
    filenames = {
        "HK_DIRECT_UUID": "hk-direct-uuid",
        "US_EXIT_UUID": "us-exit-uuid",
        "REALITY_PRIVATE_KEY": "reality-private-key",
        "REALITY_SHORT_ID": "reality-short-id",
        "TAILNET_SOCKS_USER": "tailnet-socks-user",
        "TAILNET_SOCKS_PASSWORD": "tailnet-socks-password",
        "SACHI_SOCKS_USER": "sachi-socks-user",
        "SACHI_SOCKS_PASSWORD": "sachi-socks-password",
    }
    credentials = {}
    for marker, filename in filenames.items():
        value = (credential_dir / filename).read_text().strip()
        if not value or "@" in value:
            raise SystemExit(f"missing or invalid credential: {filename}")
        credentials[marker] = value

    config = replace_markers(json.loads(template_path.read_text()), credentials)
    output_path.write_text(json.dumps(config, indent=2) + "\n")
    output_path.chmod(0o600)


if __name__ == "__main__":
    main()
