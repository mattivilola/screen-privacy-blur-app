#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"
cd "$REPO_ROOT"

: "${SCREEN_PRIVACY_SIGNING_IDENTITY:?Set SCREEN_PRIVACY_SIGNING_IDENTITY to the Developer ID Application identity.}"
: "${SCREEN_PRIVACY_NOTARY_PROFILE:?Set SCREEN_PRIVACY_NOTARY_PROFILE to an existing notarytool profile.}"
: "${SPARKLE_KEY_ACCOUNT:=screen-privacy}"
require_command git
require_command gh
require_command xcrun
require_command security
assert_developer_id_identity_available "$SCREEN_PRIVACY_SIGNING_IDENTITY"
[[ -z "$(git status --porcelain)" ]] || fail "Commit or otherwise resolve working-tree changes before releasing."
[[ "$(git branch --show-current)" == "main" ]] || fail "Run releases from the primary main checkout."
[[ "$(git rev-parse --is-shallow-repository)" == false ]] || fail "Fetch complete Git history before releasing."
git fetch origin main >/dev/null
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "HEAD differs from fresh origin/main."
local_version="$(version)"
[[ "$(build_number)" == <-> ]] || fail "CFBundleVersion must be an increasing integer."
if gh release view "v$local_version" --repo mattivilola/screen-privacy-blur-app >/dev/null 2>&1; then
  fail "GitHub release v$local_version already exists; increment the version first."
fi
sparkle_bin="$(sparkle_bin_dir)"
[[ -x "$sparkle_bin/generate_appcast" && -x "$sparkle_bin/sign_update" && -x "$sparkle_bin/generate_keys" ]] || fail "Resolve Sparkle first: swift package resolve."
expected_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
actual_key="$("$sparkle_bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
[[ "$expected_key" == "$actual_key" ]] || fail "Sparkle public key in Info.plist does not match the local Keychain key."
xcrun notarytool history --keychain-profile "$SCREEN_PRIVACY_NOTARY_PROFILE" >/dev/null || fail "Notarytool profile '$SCREEN_PRIVACY_NOTARY_PROFILE' is unavailable. Run make setup-notary APPLE_ID=<email>."
gh auth status --hostname github.com >/dev/null || fail "Authenticate gh with access to mattivilola/screen-privacy-blur-app."
gh repo view mattivilola/screen-privacy-blur-app --json nameWithOwner --jq .nameWithOwner | grep -Fqx mattivilola/screen-privacy-blur-app || fail "GitHub repository is unavailable."
print "Release prerequisites passed for v$local_version at $(git rev-parse HEAD)."
