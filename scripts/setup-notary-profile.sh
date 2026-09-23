#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"

[[ -n "${APPLE_ID:-}" ]] || fail "Pass APPLE_ID=your-Apple-account-email to make setup-notary."
[[ -n "${APPLE_TEAM_ID:-}" ]] || fail "Pass APPLE_TEAM_ID=<Developer-ID-team-id> to make setup-notary."
: "${SCREEN_PRIVACY_NOTARY_PROFILE:=NomadDashboardNotary}"
require_command xcrun
print "Storing notarytool profile '$SCREEN_PRIVACY_NOTARY_PROFILE' in your login Keychain. Enter the app-specific password at the Apple prompt; do not save it in this repository."
xcrun notarytool store-credentials "$SCREEN_PRIVACY_NOTARY_PROFILE" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID"
xcrun notarytool history --keychain-profile "$SCREEN_PRIVACY_NOTARY_PROFILE" >/dev/null
print "Notarytool profile is available: $SCREEN_PRIVACY_NOTARY_PROFILE"
