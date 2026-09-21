#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

output_dir="$(absolute_new_directory "${1:-$REPO_ROOT/artifacts/local/$(date -u +%Y%m%dT%H%M%SZ)}")"
require_command swift
require_command codesign
require_new_path "$output_dir"
mkdir -p "$output_dir"
swiftpm_args=()
[[ "${SWIFTPM_DISABLE_SANDBOX:-false}" == "true" ]] && swiftpm_args+=(--disable-sandbox)
swift build "${swiftpm_args[@]}" --configuration debug --product "$EXECUTABLE"
binary="$(swift build "${swiftpm_args[@]}" --show-bin-path --configuration debug)/$EXECUTABLE"
[[ -x "$binary" ]] || fail "SwiftPM did not produce $binary"
app_path="$output_dir/$APP_NAME"
bundle_app "$binary" "$app_path"
codesign --force --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
print "Local ad-hoc signed app: $app_path"
