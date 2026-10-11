#!/bin/bash
# Fixed managed root; --force bypasses age, never active/pinned protection.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$script_dir/local_evidence.py" cleanup "$@"
