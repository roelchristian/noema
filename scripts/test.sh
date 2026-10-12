#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Legacy Swift test options keep the complete functional graph. Explicit tiers
# choose a graph before SwiftPM starts; --filter only narrows execution within it.
tier=${NOEMA_TEST_TIER:-extended}
if [[ ${1:-} == (quick|standard|extended|specialized) ]]; then
  tier=$1
  shift
elif [[ ${NOEMA_PERFORMANCE_TESTS:-0} == 1 || ${NOEMA_VISUAL_VALIDATION:-0} == 1 || ${NOEMA_FIXTURE_VALIDATION:-0} == 1 ]]; then
  tier=specialized
fi
swift_args=()
while (( $# )); do
  case "$1" in
    --targets)
      (( $# >= 2 )) || { print -u2 'test.sh: --targets requires comma-separated test target names'; exit 2; }
      export NOEMA_TEST_TARGETS=$2
      shift 2 ;;
    --targets=*) export NOEMA_TEST_TARGETS=${1#--targets=}; shift ;;
    *) swift_args+=("$1"); shift ;;
  esac
done
case "$tier" in
  quick|extended) ;;
  standard)
    [[ -n ${NOEMA_TEST_TARGETS:-} ]] || { print -u2 'test.sh: standard requires --targets VaultCoreTests[,OtherTests]'; exit 2; }
    for target in ${(s:,:)NOEMA_TEST_TARGETS}; do
      [[ $target == (VaultCoreTests|NativeAuthenticationTests|ExternalAITests|NoemaBrandTests|NoemaEditorTests) ]] || { print -u2 "test.sh: unknown functional test target: $target"; exit 2; }
    done ;;
  specialized)
    [[ ${NOEMA_PERFORMANCE_TESTS:-0} == 1 || ${NOEMA_VISUAL_VALIDATION:-0} == 1 || ${NOEMA_FIXTURE_VALIDATION:-0} == 1 ]] || { print -u2 'test.sh: specialized requires a performance, visual, or fixture validation gate'; exit 2; } ;;
  *) print -u2 "test.sh: unknown tier: $tier"; exit 2 ;;
esac
export NOEMA_TEST_TIER=$tier
# SwiftPM shares the test executable across graphs. Permit --skip-build only
# after this wrapper successfully built the same graph; invalidate on failures.
build_directory="$PWD/.build"
configuration=debug
index=1
while (( index <= ${#swift_args} )); do
  argument=${swift_args[$index]}
  case "$argument" in
    --scratch-path) (( index++ )); build_directory=${swift_args[$index]:-} ;;
    --scratch-path=*) build_directory=${argument#--scratch-path=} ;;
    -c|--configuration) (( index++ )); configuration=${swift_args[$index]:-} ;;
    --configuration=*) configuration=${argument#--configuration=} ;;
  esac
  (( index++ ))
done
[[ $build_directory == /* ]] || build_directory="$PWD/$build_directory"
graph="$tier:$configuration"
[[ $tier != standard ]] || graph+=":${NOEMA_TEST_TARGETS}"
if [[ $tier == (extended|specialized) ]]; then
  graph+=":${NOEMA_PERFORMANCE_TESTS:-0}:${NOEMA_VISUAL_VALIDATION:-0}:${NOEMA_FIXTURE_VALIDATION:-0}"
fi
stamp="$build_directory/noema-test-graph"
skip_build=0
for argument in "${swift_args[@]}"; do
  [[ $argument != --skip-build ]] || skip_build=1
done
if (( skip_build )); then
  [[ -f $stamp && $(<$stamp) == $graph ]] || { print -u2 "test.sh: --skip-build requires a successful prior run of the same $tier graph"; exit 2; }
else
  rm -f "$stamp"
fi
python3 scripts/check-storage-boundary.py --selftest
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
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "${extra_flags[@]}" "${swift_args[@]}"

mkdir -p "${stamp:h}"
print -r -- "$graph" > "$stamp"

# Retain failures; expire only completed, unpinned local runs after success.
./scripts/cleanup-local-evidence.sh --older-than 7d --protect-active
