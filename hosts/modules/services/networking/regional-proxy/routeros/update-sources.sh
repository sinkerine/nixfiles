#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
output=${1:-generated-lists.rsc}
# Compatibility entrypoint: local explicit domains only, no remote rule sets.
python3 "$here/allowlist.py" render > "$output"
echo "Wrote $output from the local HK domain allowlist (no GeoIP)."
