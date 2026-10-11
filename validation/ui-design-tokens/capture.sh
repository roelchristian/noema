#!/bin/bash
# UI.TK07: deterministic native fixtures; no application preferences are changed.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
output="${1:-$repo_root/validation/ui-design-tokens/generated/after}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
if [[ -n "${BASELINE_REF:-}" ]]; then
    snapshot_root="$(mktemp -d "${TMPDIR:-/tmp}/noema-token-baseline.XXXXXX")"
    trap 'rm -rf "$snapshot_root"' EXIT
    git -C "$repo_root" archive "$BASELINE_REF" | tar -x -C "$snapshot_root"
    cp "$repo_root/Tests/NoemaEditorTests/DesignTokenValidationTests.swift" "$snapshot_root/Tests/NoemaEditorTests/"
    cd "$snapshot_root"
else
    cd "$repo_root"
fi
NOEMA_TOKEN_SCREENSHOT_DIR="$output" ./scripts/test.sh --filter DesignTokenValidationTests
if [[ -n "${BASELINE_REF:-}" ]]; then
    git -C "$repo_root" rev-parse "$BASELINE_REF" > "$output/source-ref.txt"
else
    git -C "$repo_root" rev-parse HEAD > "$output/source-ref.txt"
fi
sw_vers > "$output/platform.txt"
swift --version >> "$output/platform.txt"
