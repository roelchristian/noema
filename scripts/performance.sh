#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Benchmark sources enter the graph only through this opt-in target.
export NOEMA_PERFORMANCE_TESTS=1
exec ./scripts/test.sh specialized --filter '[.]benchmark|/benchmark|^benchmark' "$@"
