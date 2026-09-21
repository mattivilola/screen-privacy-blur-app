#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

[[ $# -eq 1 ]] || fail "Usage: $0 <release-output-directory>"
release_dir="$(cd "$1" && pwd)"
app_path="$release_dir/$APP_NAME"
[[ -d "$app_path" ]] || fail "Missing app bundle: $app_path"
: "${SCREEN_PRIVACY_NOTARY_PROFILE:?Set SCREEN_PRIVACY_NOTARY_PROFILE to an existing notarytool keychain profile.}"
: "${SCREEN_PRIVACY_SIGNING_IDENTITY:?Set SCREEN_PRIVACY_SIGNING_IDENTITY to the Developer ID identity used for this app.}"
require_command ditto
require_command xcrun
require_command shasum
require_command security
assert_developer_id_identity_available "$SCREEN_PRIVACY_SIGNING_IDENTITY"
assert_release_signed_app "$app_path" "$SCREEN_PRIVACY_SIGNING_IDENTITY"
release_version="$(bundle_version "$app_path")"
require_new_path "$release_dir/ScreenPrivacy-$release_version.notary.zip"
require_new_path "$release_dir/ScreenPrivacy-$release_version.zip"
require_new_path "$release_dir/ScreenPrivacy-$release_version.zip.sha256"
require_new_path "$release_dir/notary-result.json"

notary_zip="$release_dir/ScreenPrivacy-$release_version.notary.zip"
final_zip="$release_dir/ScreenPrivacy-$release_version.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$notary_zip"
xcrun notarytool submit "$notary_zip" --keychain-profile "$SCREEN_PRIVACY_NOTARY_PROFILE" --wait --output-format json > "$release_dir/notary-result.json"
grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$release_dir/notary-result.json" || fail "Notarization did not return Accepted; see $release_dir/notary-result.json"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_zip"
(cd "$release_dir" && shasum -a 256 "${final_zip:t}") > "$final_zip.sha256"
print "Notarized ZIP: $final_zip"
