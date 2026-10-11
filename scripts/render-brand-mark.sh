#!/bin/bash
set -euo pipefail

# Render production SwiftUI branding without SwiftPM, app launch, or UserDefaults.
# Usage: scripts/render-brand-mark.sh OUTPUT_DIRECTORY
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    exit 1
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/noema-brand-mark.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc -module-cache-path "$build_dir/module-cache" -parse-as-library -emit-module -emit-library -module-name NoemaBrand \
    "$repo_dir"/Sources/NoemaBrand/*.swift \
    -emit-module-path "$build_dir/NoemaBrand.swiftmodule" -o "$build_dir/libNoemaBrand.dylib"
xcrun swiftc -module-cache-path "$build_dir/module-cache" -parse-as-library -I "$build_dir" -L "$build_dir" -lNoemaBrand \
    -Xlinker -rpath -Xlinker "$build_dir" \
    "$repo_dir/Sources/noema/NoemaMark.swift" \
    "$repo_dir/Sources/noema/Theme.swift" \
    "$repo_dir/Sources/noema/ThemePalettePicker.swift" \
    "$repo_dir/scripts/BrandMarkVerification.swift" \
    -o "$build_dir/render-brand-mark"
"$build_dir/render-brand-mark" "$1"
