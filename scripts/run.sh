#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh "${1:-debug}"
open "$PWD/dist/noema.app"
