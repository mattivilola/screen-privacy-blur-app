#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

[[ $# -eq 1 ]] || fail "Usage: $0 <release-output-directory>"
release_dir="$(cd "$1" && pwd)"
app_path="$release_dir/$APP_NAME"
[[ -d "$app_path" ]] || fail "Missing app bundle: $app_path"
require_command hdiutil
require_command shasum
release_version="$(bundle_version "$app_path")"
dmg="$release_dir/ScreenPrivacy-$release_version.dmg"
staging_dir="$release_dir/.dmg-staging"
require_new_path "$dmg"
require_new_path "$dmg.sha256"
require_new_path "$staging_dir"
if [[ -n "${SCREEN_PRIVACY_NOTARY_PROFILE:-}" ]]; then
  : "${SCREEN_PRIVACY_SIGNING_IDENTITY:?Set SCREEN_PRIVACY_SIGNING_IDENTITY before signing/notarizing the DMG.}"
  require_command security
  require_command xcrun
  assert_developer_id_identity_available "$SCREEN_PRIVACY_SIGNING_IDENTITY"
  assert_release_signed_app "$app_path" "$SCREEN_PRIVACY_SIGNING_IDENTITY"
  xcrun stapler validate "$app_path"
  require_new_path "$release_dir/dmg-notary-result.json"
fi
mkdir "$staging_dir"
cp -R "$app_path" "$staging_dir/$APP_NAME"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -volname "Screen Privacy" -srcfolder "$staging_dir" -format UDZO -imagekey zlib-level=9 "$dmg" >/dev/null
if [[ -n "${SCREEN_PRIVACY_NOTARY_PROFILE:-}" ]]; then
  codesign --force --sign "$SCREEN_PRIVACY_SIGNING_IDENTITY" --timestamp "$dmg"
  codesign --verify --verbose=2 "$dmg"
  xcrun notarytool submit "$dmg" --keychain-profile "$SCREEN_PRIVACY_NOTARY_PROFILE" --wait --output-format json > "$release_dir/dmg-notary-result.json"
  grep -Eq '"status"[[:space:]]*:[[:space:]]*"Accepted"' "$release_dir/dmg-notary-result.json" || fail "DMG notarization did not return Accepted; see $release_dir/dmg-notary-result.json"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
else
  print "Created an unsigned, unnotarized DMG; set SCREEN_PRIVACY_NOTARY_PROFILE to notarize and staple it."
fi
(cd "$release_dir" && shasum -a 256 "${dmg:t}") > "$dmg.sha256"
print "DMG: $dmg"
