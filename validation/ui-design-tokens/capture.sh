#!/bin/bash
# Current design-token visual-validation harness; all captures stay in ignored managed runs.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
exec python3 "$repo_root/scripts/local_evidence.py" capture "$@"
