# Releasing Screen Privacy

Screen Privacy is a direct-download macOS app. The repository has no stored signing identities, Apple credentials, or notary credentials. GitHub Actions only builds an unsigned universal candidate and uploads it as an artifact; it never publishes a release.

## Local development app

`./scripts/build-local-app.sh` builds the SwiftPM executable, creates a new timestamped app bundle under `artifacts/local/`, and applies an ad-hoc signature. Pass a new directory explicitly to control the destination. The script refuses to overwrite an existing path.

When running inside a restricted execution sandbox that blocks SwiftPM's manifest sandbox, set `SWIFTPM_DISABLE_SANDBOX=true` for the command. This is unnecessary on a normal release Mac or GitHub-hosted runner.

## Distribution prerequisites

Use a release Mac with Xcode command-line tools, a valid **Developer ID Application** certificate, and a notarization keychain profile. Store the profile outside the repository, for example with:

```sh
xcrun notarytool store-credentials ScreenPrivacyNotary --apple-id 'you@example.com' --team-id 'YOUR_TEAM_ID'
```

Set these only in the release shell:

```sh
export SCREEN_PRIVACY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export SCREEN_PRIVACY_NOTARY_PROFILE=ScreenPrivacyNotary
```

The shipped bundle uses `com.iloapps.screenprivacy`, version `0.1.0` build `1`, macOS 14 minimum, hardened runtime, and the camera entitlement. Change version metadata in `Packaging/Info.plist` deliberately before a new release.

## Build, sign, notarize, package

Choose an unused release directory. Every script fails on a collision so a prior artifact is never silently replaced.

```sh
release_dir="artifacts/release/v0.1.0-build1-$(date -u +%Y%m%dT%H%M%SZ)"
./scripts/build-release-app.sh --output-dir "$release_dir"
./scripts/notarize-release.sh "$release_dir"
./scripts/create-dmg.sh "$release_dir"
```

`build-release-app.sh` verifies that `ScreenPrivacy` contains both `arm64` and `x86_64` before it signs `Screen Privacy.app` with hardened runtime and the camera entitlement. `notarize-release.sh` rejects unsigned, ad-hoc, wrong-identity, and non-hardened apps before it submits a temporary ZIP. It requires an explicit `Accepted` result, staples the app, creates the final ZIP, and writes a neighboring `.sha256` file. `create-dmg.sh` creates a DMG containing the app and an `/Applications` link, signs it before submission, requires `Accepted`, staples it, and writes its own `.sha256` file. Artifact names use the actual bundle `Info.plist` version.

Before distributing, inspect the signed app and installed DMG manually:

```sh
codesign --verify --deep --strict --verbose=2 "$release_dir/Screen Privacy.app"
spctl -a -vv "$release_dir/Screen Privacy.app"
xcrun stapler validate "$release_dir/Screen Privacy.app"
xcrun stapler validate "$release_dir/ScreenPrivacy-0.1.0.dmg"
cat "$release_dir"/*.sha256
```

Notarization is not needed for the local ad-hoc development build. The manual workflow intentionally omits Developer ID and notary secrets: download the artifact only as a build candidate, then use the local signed flow above for distribution.

## Source and release publishing

The MIT-licensed source is hosted at [mattivilola/screen-privacy-blur-app](https://github.com/mattivilola/screen-privacy-blur-app). Build releases from a clean, reviewed commit.

Before publishing a binary, complete the hardware checklist in `docs/VALIDATION.md`, run `swift test` and `./scripts/test-release-tools.sh`, confirm the release commit is clean, and retain that commit SHA with the artifacts. Build from that commit. Signed binaries and notarization require your own Apple Developer credentials; forks should use their own bundle identifier and identity. Publish only final ZIP/DMG files and their `.sha256` files, not submission ZIPs or Keychain data. Notary JSON responses are local diagnostic artifacts.

The GitHub Actions workflows provide source build/test verification and downloadable unsigned candidates. They do not prove Gatekeeper acceptance, notarization, camera behavior, or energy use, and they never publish releases themselves.
