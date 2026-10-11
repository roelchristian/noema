#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/check-storage-boundary.py
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
extra_flags=()
if [[ -d "$frameworks/Testing.framework" ]]; then
  extra_flags=(-Xswiftc -F -Xswiftc "$frameworks"
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
    -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
    -Xlinker -rpath -Xlinker "$frameworks")
fi
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "${extra_flags[@]}" "$@"
