#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration=${1:-release}
python3 scripts/check-storage-boundary.py
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox -c "$configuration" --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
binary_dir=$(swift build --disable-sandbox -c "$configuration" --show-bin-path)
app="$PWD/dist/noema.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/noema" "$app/Contents/MacOS/noema"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$PWD/.build/VaultIcon.iconset"
swiftc -module-cache-path "$PWD/.build/ModuleCache" Sources/NoemaBrand/OrbitGeometry.swift Sources/NoemaBrand/MidnightIris.swift Sources/NoemaBrand/NoemaBrandPalette.swift scripts/Icon.swift -o "$PWD/.build/icon-generator"
"$PWD/.build/icon-generator" "$PWD/.build/VaultIcon.iconset" "$PWD/Resources/Brand"
iconutil -c icns "$PWD/.build/VaultIcon.iconset" -o "$app/Contents/Resources/VaultIcon.icns"
for bundle in "$binary_dir"/*.bundle(N); do cp -R "$bundle" "$app/Contents/Resources/"; done
# Finder/iCloud metadata on generated assets must not enter the code signature.
xattr -cr "$app"
codesign --force --sign - --entitlements Resources/Vault.entitlements "$app"
# The archive omits Finder/iCloud extended attributes and keeps the signed bundle.
ditto -c -k --keepParent --norsrc --noextattr "$app" "$PWD/dist/noema.zip"
echo "Built: $app"
echo "Archive: $PWD/dist/noema.zip"
