#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Screen Privacy.app"
EXECUTABLE="ScreenPrivacy"
INFO_PLIST="$REPO_ROOT/Packaging/Info.plist"
ENTITLEMENTS="$REPO_ROOT/Packaging/ScreenPrivacy.entitlements"

fail() { print -u2 -- "$1"; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
require_new_path() { [[ ! -e "$1" && ! -L "$1" ]] || fail "Refusing to overwrite existing output: $1"; }
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST"; }
build_number() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST"; }
sparkle_bin_dir() { print -- "$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin"; }
bundle_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist"; }
absolute_new_directory() { local requested="$1"; mkdir -p "${requested:h}"; print -- "$(cd "${requested:h}" && pwd)/${requested:t}"; }
assert_developer_id_identity_available() { [[ "$1" == Developer\ ID\ Application:* ]] || fail "SCREEN_PRIVACY_SIGNING_IDENTITY must be a Developer ID Application identity."; security find-identity -v -p codesigning | grep -Fq "$1" || fail "Developer ID signing identity is unavailable in the current keychain."; }
assert_release_signed_app() {
  local details
  codesign --verify --deep --strict --verbose=2 "$1" || fail "App signature verification failed."
  details="$(codesign -d --verbose=4 "$1" 2>&1)" || fail "Cannot inspect app signature."
  print -r -- "$details" | grep -Fqx "Authority=$2" || fail "App is not signed by the configured Developer ID identity."
  print -r -- "$details" | grep -Eq 'flags=.*runtime' || fail "App does not have hardened runtime enabled."
  if print -r -- "$details" | grep -Fq 'Signature=adhoc'; then
    fail "App has an ad-hoc signature."
  fi
  return 0
}

bundle_app() {
  local binary="$1" app_path="$2"
  require_new_path "$app_path"
  mkdir -p "$app_path/Contents/MacOS"
  cp "$INFO_PLIST" "$app_path/Contents/Info.plist"
  cp "$binary" "$app_path/Contents/MacOS/$EXECUTABLE"
  local framework_source="${binary:h}/Sparkle.framework"
  [[ -d "$framework_source" ]] || fail "SwiftPM did not provide Sparkle.framework beside $binary"
  mkdir -p "$app_path/Contents/Frameworks"
  ditto "$framework_source" "$app_path/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$app_path/Contents/MacOS/$EXECUTABLE"
  mkdir -p "$app_path/Contents/Resources"
  cp "$REPO_ROOT/LICENSE" "$app_path/Contents/Resources/LICENSE.txt"
  cp "$REPO_ROOT/THIRD_PARTY_NOTICES.txt" "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.txt"
  if [[ -f "$REPO_ROOT/Packaging/AppIcon.icns" ]]; then
    cp "$REPO_ROOT/Packaging/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$app_path/Contents/Info.plist"
  fi
  if [[ -f "$REPO_ROOT/Assets/Logo.png" ]]; then
    cp "$REPO_ROOT/Assets/Logo.png" "$app_path/Contents/Resources/Logo.png"
  fi
  if [[ -f "$REPO_ROOT/Assets/AppIcon.png" ]]; then
    cp "$REPO_ROOT/Assets/AppIcon.png" "$app_path/Contents/Resources/AppIcon.png"
  fi
}

sign_sparkle_components() {
  local app_path="$1" identity="$2" root="$app_path/Contents/Frameworks/Sparkle.framework/Versions/Current"
  [[ -d "$root" ]] || fail "Sparkle.framework is missing from $app_path"
  local signing_args=(--force --sign "$identity")
  if [[ "$identity" != "-" ]]; then
    signing_args+=(--timestamp --options runtime --preserve-metadata=identifier,entitlements,flags)
  fi
  local component
  for component in \
    "$root/Autoupdate" \
    "$root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$root/XPCServices/Downloader.xpc" \
    "$root/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$root/XPCServices/Installer.xpc" \
    "$root/Updater.app/Contents/MacOS/Updater" \
    "$root/Updater.app" \
    "$app_path/Contents/Frameworks/Sparkle.framework"; do
    [[ -e "$component" ]] || fail "Missing Sparkle component: $component"
    codesign "${signing_args[@]}" "$component"
  done
}
