#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

unsigned=false
output_dir=""
while (( $# > 0 )); do
  case "$1" in
    --unsigned) unsigned=true; shift ;;
    --output-dir) output_dir="${2:-}"; shift 2 ;;
    *) fail "Usage: $0 --output-dir <new-directory> [--unsigned]" ;;
  esac
done
[[ -n "$output_dir" ]] || fail "--output-dir is required to avoid overwriting a release artifact."
output_dir="$(absolute_new_directory "$output_dir")"
require_command swift
require_command codesign
if [[ "$unsigned" != true ]]; then
  : "${SCREEN_PRIVACY_SIGNING_IDENTITY:?Set SCREEN_PRIVACY_SIGNING_IDENTITY to a Developer ID Application identity.}"
  require_command security
  assert_developer_id_identity_available "$SCREEN_PRIVACY_SIGNING_IDENTITY"
fi
require_new_path "$output_dir"
mkdir -p "$output_dir"
swiftpm_args=()
[[ "${SWIFTPM_DISABLE_SANDBOX:-false}" == "true" ]] && swiftpm_args+=(--disable-sandbox)
swift build "${swiftpm_args[@]}" --configuration release --product "$EXECUTABLE" --arch arm64 --arch x86_64
binary="$(swift build "${swiftpm_args[@]}" --show-bin-path --configuration release --arch arm64 --arch x86_64)/$EXECUTABLE"
[[ -x "$binary" ]] || fail "SwiftPM did not produce $binary"
lipo "$binary" -verify_arch arm64 x86_64
app_path="$output_dir/$APP_NAME"
bundle_app "$binary" "$app_path"
if [[ "$unsigned" == true ]]; then
  print "Created unsigned universal app for CI: $app_path"
else
  codesign --force --sign "$SCREEN_PRIVACY_SIGNING_IDENTITY" --timestamp --options runtime --entitlements "$ENTITLEMENTS" "$app_path"
  assert_release_signed_app "$app_path" "$SCREEN_PRIVACY_SIGNING_IDENTITY"
  codesign -d --entitlements :- "$app_path" 2>&1 | grep -Fq 'com.apple.security.device.camera' || fail "Camera entitlement is missing after signing."
fi
print "Release app: $app_path"
