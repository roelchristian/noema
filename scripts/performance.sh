#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# All performance workloads share one opt-in gate and benchmark name prefix.
# Routine test runs report them as skipped instead of executing timing workloads.
export NOEMA_PERFORMANCE_TESTS=1
exec ./scripts/test.sh --filter '[.]benchmark|/benchmark|^benchmark' "$@"
