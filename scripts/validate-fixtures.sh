#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Load fixture quality checks only for this explicit validation command.
export NOEMA_FIXTURE_VALIDATION=1
exec ./scripts/test.sh --filter NoemaFixtureValidationTests "$@"
