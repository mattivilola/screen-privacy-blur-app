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
tag="v$release_version"
[[ "$release_version" == "$(version)" ]] || fail "Bundle version differs from Packaging/Info.plist."
[[ -z "$(git status --porcelain)" ]] || fail "Commit all source changes before publishing."
git fetch origin main >/dev/null
head_sha="$(git rev-parse HEAD)"
[[ "$head_sha" == "$(git rev-parse origin/main)" ]] || fail "HEAD differs from fresh origin/main."
[[ -f "$release_dir/source-commit.txt" && "$(cat "$release_dir/source-commit.txt")" == "$head_sha" ]] || fail "Release artifact was not built from current HEAD. Rebuild from the committed source."
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
  fail "Tag $tag already exists on origin; refusing to publish a duplicate or change its target."
fi
if gh release view "$tag" --repo mattivilola/screen-privacy-blur-app >/dev/null 2>&1; then
  fail "GitHub release $tag already exists."
fi
: "${SCREEN_PRIVACY_SIGNING_IDENTITY:?Set SCREEN_PRIVACY_SIGNING_IDENTITY.}"
: "${SPARKLE_KEY_ACCOUNT:=screen-privacy}"
assert_release_signed_app "$app_path" "$SCREEN_PRIVACY_SIGNING_IDENTITY"
xcrun stapler validate "$app_path" >/dev/null || fail "App is not stapled/notarized."
dmg="$release_dir/ScreenPrivacy-$release_version.dmg"
zip="$release_dir/ScreenPrivacy-$release_version.zip"
feed="$release_dir/appcast.xml"
for file in "$dmg" "$zip" "$feed"; do
  [[ -s "$file" && -s "$file.sha256" ]] || fail "Missing release artifact or checksum: $file"
  (cd "$release_dir" && shasum -a 256 -c "${file:t}.sha256") || fail "Checksum failed: $file"
done
xcrun stapler validate "$dmg" >/dev/null || fail "DMG is not stapled/notarized."
"$(sparkle_bin_dir)/sign_update" --account "$SPARKLE_KEY_ACCOUNT" --verify "$feed" || fail "Appcast signature is invalid."
python3 - "$feed" "$dmg" "$tag" <<'PY'
import sys, xml.etree.ElementTree as ET
feed_path, dmg_path, tag = sys.argv[1:]
root = ET.parse(feed_path).getroot()
urls = [item.attrib.get('url', '') for item in root.iter('enclosure')]
expected = f'https://github.com/mattivilola/screen-privacy-blur-app/releases/download/{tag}/{dmg_path.rsplit("/", 1)[-1]}'
if expected not in urls:
    raise SystemExit(f'Appcast does not point at this immutable DMG: {expected}')
PY
[[ -s "$release_dir/release-notes.md" ]] || fail "Missing release notes."
gh auth status --hostname github.com >/dev/null || fail "Authenticate gh before publishing."
git fetch origin main >/dev/null
[[ "$head_sha" == "$(git rev-parse origin/main)" ]] || fail "origin/main moved during release verification; rebuild from the new target."
gh release create "$tag" \
  --repo mattivilola/screen-privacy-blur-app \
  --target "$head_sha" \
  --latest \
  --title "Screen Privacy $release_version" \
  --notes-file "$release_dir/release-notes.md" \
  "$dmg" "$dmg.sha256" "$zip" "$zip.sha256" "$feed" "$feed.sha256"
gh release view "$tag" --repo mattivilola/screen-privacy-blur-app --json url,assets --jq '{url: .url, assets: [.assets[].name]}'
print "Release published. Verify https://github.com/mattivilola/screen-privacy-blur-app/releases/latest/download/appcast.xml anonymously before announcing it."
