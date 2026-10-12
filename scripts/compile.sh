#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Compile the executable without packaging, icon generation, or signing.
export NOEMA_TEST_TIER=compile
python3 scripts/check-storage-boundary.py --selftest
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "$@"
./scripts/cleanup-local-evidence.sh --older-than 7d --protect-active
