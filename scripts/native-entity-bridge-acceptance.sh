#!/bin/zsh
# Build an isolated QA application containing real native views and synthetic vaults.
set -euo pipefail
cd "${0:A:h:h}"
phase=4
run_id="entity-bridge-native-$(date -u +%Y%m%dT%H%M%SZ)"
launch=0
while (( $# )); do
  case "$1" in
    --phase) phase=$2; shift 2 ;;
    --run-id) run_id=$2; shift 2 ;;
    --launch) launch=1; shift ;;
    --skip-update) shift ;; # Explicitly accepted; all builds below skip updating dependencies.
    *) print -u2 "Unknown argument: $1"; exit 2 ;;
  esac
done
[[ $phase == (4|5) ]] || { print -u2 'phase must be 4 or 5'; exit 2; }
[[ $run_id == [a-zA-Z0-9]* && $run_id != *[^a-zA-Z0-9_-]* && ${#run_id} -le 80 ]] || { print -u2 'Use a simple managed run ID'; exit 2; }
if [[ $phase == 5 && ! -f Sources/noema/Inspector/SourceEntityLinksView.swift ]]; then
  print -u2 'ENT05 views must be integrated before building phase 5'; exit 2
fi
run="$PWD/.local/agent-runs/$run_id"
[[ ! -e $run ]] || { print -u2 "Run already exists: $run"; exit 2; }
mkdir -p "$run"
touch "$run/.active" "$run/.pinned" "$run/.qa-owned"
native_running=0
finish() {
  local outcome=$?
  if (( outcome )); then touch "$run/.failed"; fi
  # If open -W was interrupted, preserve active protection until the QA app is closed.
  if (( ! native_running )); then touch "$run/.complete"; rm -f "$run/.active"; fi
}
trap finish EXIT
export NOEMA_TEST_TIER=compile NOEMA_ENTITY_BRIDGE_NATIVE=1 NOEMA_ENTITY_BRIDGE_PHASE=$phase
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
print "Building isolated ENT0$phase QA application. Evidence: $run"
swift build --disable-sandbox --skip-update --product noema -Xswiftc -enable-testing > "$run/application-objects-build.log" 2>&1 || {
  tail -60 "$run/application-objects-build.log"; exit 1
}
bin=$(swift build --show-bin-path)
python3 - "$bin" "$run/noema-objects.list" <<'PY'
from pathlib import Path
import sys
objects = sorted((Path(sys.argv[1]) / 'noema.build').glob('*.o'))
objects = [path for path in objects if path.name.casefold() != 'noemaapp.swift.o']
if not objects or not any(path.name == 'AppModel.swift.o' for path in objects):
    raise SystemExit('Cannot locate compiled application view objects')
Path(sys.argv[2]).write_text(''.join(str(path) + '\n' for path in objects))
PY
export NOEMA_ENTITY_BRIDGE_OBJECTS="$run/noema-objects.list"
swift build --disable-sandbox --skip-update --product NoemaEntityBridgeQA -Xswiftc -enable-testing > "$run/build.log" 2>&1 || {
  tail -60 "$run/build.log"; exit 1
}
bundle="$run/Noema Entity Bridge QA.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/NoemaEntityBridgeQA" "$bundle/Contents/MacOS/NoemaEntityBridgeQA"
[[ ! -d "$bin/noema_noema.bundle" ]] || ditto "$bin/noema_noema.bundle" "$bundle/Contents/Resources/noema_noema.bundle"
qa_id="com.noema.qa.entitybridge.$(uuidgen | tr '[:upper:]' '[:lower:]')"
python3 - "$bundle/Contents/Info.plist" "$qa_id" "$run" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'CFBundleIdentifier': sys.argv[2], 'CFBundleExecutable': 'NoemaEntityBridgeQA',
                  'CFBundleName': 'Noema Entity Bridge QA', 'CFBundlePackageType': 'APPL',
                  'CFBundleVersion': '1', 'LSMinimumSystemVersion': '26.0',
                  'NSHighResolutionCapable': True, 'NoemaQARunRoot': sys.argv[3]}, output)
PY
codesign --force --deep --sign - "$bundle" > "$run/codesign.log" 2>&1
print "$bundle" > "$run/bundle-path.txt"
print "QA bundle: $bundle"
print 'Native keyboard and VoiceOver acceptance must be observed and recorded; build success is not acceptance.'
if (( launch )); then
  native_running=1
  open -W -n "$bundle" > "$run/launch.log" 2>&1
  native_running=0
fi
