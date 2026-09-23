#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

[[ $# -eq 1 ]] || fail "Usage: $0 <release-output-directory>"
release_dir="$(cd "$1" && pwd)"
app_path="$release_dir/$APP_NAME"
[[ -d "$app_path" ]] || fail "Missing release app in $release_dir"
release_version="$(bundle_version "$app_path")"
[[ "$release_version" == "$(version)" ]] || fail "Bundle version differs from Packaging/Info.plist."
: "${SCREEN_PRIVACY_SIGNING_IDENTITY:?Set SCREEN_PRIVACY_SIGNING_IDENTITY.}"
: "${SPARKLE_KEY_ACCOUNT:=screen-privacy}"
assert_release_signed_app "$app_path" "$SCREEN_PRIVACY_SIGNING_IDENTITY"
dmg="$release_dir/ScreenPrivacy-$release_version.dmg"
[[ -f "$dmg" ]] || fail "Missing final DMG: $dmg"
xcrun stapler validate "$dmg" >/dev/null || fail "DMG is not stapled/notarized."
(cd "$release_dir" && shasum -a 256 -c "${dmg:t}.sha256") || fail "DMG checksum failed."
feed="$release_dir/appcast.xml"
require_new_path "$feed"
require_new_path "$feed.sha256"
stage="$release_dir/.appcast-stage"
require_new_path "$stage"
sparkle_bin="$(sparkle_bin_dir)"
[[ -x "$sparkle_bin/generate_appcast" && -x "$sparkle_bin/sign_update" ]] || fail "Sparkle command-line tools are missing."
mkdir "$stage"
cp "$dmg" "$stage/"
cp "$REPO_ROOT/CHANGELOG.md" "$stage/ScreenPrivacy-$release_version.md"
"$sparkle_bin/generate_appcast" \
  --account "$SPARKLE_KEY_ACCOUNT" \
  --download-url-prefix "https://github.com/mattivilola/screen-privacy-blur-app/releases/download/v$release_version/" \
  --maximum-deltas 0 \
  --embed-release-notes \
  -o "$feed" \
  "$stage"
[[ -s "$feed" ]] || fail "Sparkle did not generate an appcast."
"$sparkle_bin/sign_update" --account "$SPARKLE_KEY_ACCOUNT" --verify "$feed"
(cd "$release_dir" && shasum -a 256 "${feed:t}") > "$feed.sha256"
cp "$REPO_ROOT/CHANGELOG.md" "$release_dir/release-notes.md"
print "Signed Sparkle feed: $feed"
