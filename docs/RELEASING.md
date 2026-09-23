# Releasing Screen Privacy

Screen Privacy is a direct-download macOS app with Sparkle updates. `make` lists every command. The private Sparkle update key, Developer ID certificate, and Apple notary credentials stay in the release Mac's Keychain. GitHub Actions builds an unsigned candidate; publication runs locally after signing and notarization.

## Local development app

`./scripts/build-local-app.sh` builds the SwiftPM executable, creates a new timestamped app bundle under `artifacts/local/`, and applies an ad-hoc signature. Pass a new directory explicitly to control the destination. The script refuses to overwrite an existing path.

When running inside a restricted execution sandbox that blocks SwiftPM's manifest sandbox, set `SWIFTPM_DISABLE_SANDBOX=true` for the command. This is unnecessary on a normal release Mac or GitHub-hosted runner.

## Distribution prerequisites

Use a release Mac with Xcode command-line tools, a valid **Developer ID Application** certificate for the app's team, a dedicated Sparkle Ed25519 private key, a notarization keychain profile, and `gh` authenticated with release permission. Create the Apple profile interactively without putting the password in a shell command or this repository:

```sh
make setup-notary APPLE_ID=you@example.com
```

The default certificate name, team ID, notary profile name, and Sparkle key account are in the Makefile. Override them when using your own fork or release Mac:

```sh
export SCREEN_PRIVACY_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export SCREEN_PRIVACY_NOTARY_PROFILE=ScreenPrivacyNotary
export SPARKLE_KEY_ACCOUNT=screen-privacy
```

The shipped bundle uses `com.iloapps.screenprivacy`, macOS 14 minimum, hardened runtime, and the camera entitlement. Change `CFBundleShortVersionString` and increase `CFBundleVersion` in `Packaging/Info.plist` before each new release. The GitHub tag is `v<short version>` and must be unused. The public Sparkle key in that plist must match the private key in the release Mac's Keychain. Do not put the private key in Git, GitHub Actions, or the release assets.

## Build, sign, notarize, package

From a clean `main` commit already pushed to `origin/main`, run:

```sh
make release-check
make release
```

`make release` checks the local Git commit, remote branch, credentials, update key, and unused tag; runs Swift and release-tool tests; builds a universal app; signs Sparkle's embedded helpers and the app with Developer ID; submits and staples the app; builds, signs, notarizes, and staples an installable DMG; generates and signs the Sparkle appcast; then uploads the final DMG, ZIP, feed, and checksums to GitHub Releases. Each stage stops on failure. The published enclosure URL names the immutable versioned DMG asset. The app checks `releases/latest/download/appcast.xml` for later versions.

To run individual stages, set one unused `RELEASE_DIR` for all commands:

```sh
make release-dry-run
make release-build RELEASE_DIR=artifacts/release/v0.1.0-build1
make release-notarize RELEASE_DIR=artifacts/release/v0.1.0-build1
make release-dmg RELEASE_DIR=artifacts/release/v0.1.0-build1
make release-appcast RELEASE_DIR=artifacts/release/v0.1.0-build1
make release-publish RELEASE_DIR=artifacts/release/v0.1.0-build1
```

The stages refuse to overwrite existing artifacts. `release-publish` also checks the saved source commit against fresh `origin/main`, app and DMG stapling, checksums, feed signature, and enclosure URL. It refuses a duplicate tag or release. Do not publish partial or unsigned results.

Before distributing, inspect the signed app and installed DMG manually:

```sh
release_dir=artifacts/release/v0.1.0-build1
codesign --verify --deep --strict --verbose=2 "$release_dir/Screen Privacy.app"
spctl -a -vv "$release_dir/Screen Privacy.app"
xcrun stapler validate "$release_dir/Screen Privacy.app"
xcrun stapler validate "$release_dir/ScreenPrivacy-0.1.0.dmg"
cat "$release_dir"/*.sha256
```

Notarization is not needed for the local ad-hoc development build. After publishing, download the DMG through its public GitHub URL on a second Mac, mount it, drag the app into `/Applications`, and confirm Gatekeeper opens it. On a later release, test **Check for Updates…** in an installed older version and confirm Sparkle upgrades it. A first release cannot prove the old-to-new update path by itself.

## Source and release publishing

The MIT-licensed source is hosted at [mattivilola/screen-privacy-blur-app](https://github.com/mattivilola/screen-privacy-blur-app). Build releases from a clean, reviewed commit.

Before publishing a binary, complete the hardware checklist in `docs/VALIDATION.md`, especially camera selection, multi-display covering, sleep/wake, permission fallback, and frozen image behavior. Publish only the final DMG/ZIP/feed and their checksums. Notary responses and Keychain material are local. Forks should use their own bundle identifier, Apple team, GitHub feed URL, and Sparkle key.

The GitHub Actions workflows provide source build/test verification and downloadable unsigned candidates. They do not prove Gatekeeper acceptance, notarization, camera behavior, or energy use, and they never publish releases themselves.
