.DEFAULT_GOAL := help

APP_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)
APP_BUILD := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Packaging/Info.plist)
RELEASE_DIR ?= artifacts/release/v$(APP_VERSION)-build$(APP_BUILD)-$(shell date -u +%Y%m%dT%H%M%SZ)
SCREEN_PRIVACY_SIGNING_IDENTITY ?= Developer ID Application: Matti Vilola (MM233FKU38)
SCREEN_PRIVACY_NOTARY_PROFILE ?= ScreenPrivacyNotary
SPARKLE_KEY_ACCOUNT ?= screen-privacy
APPLE_TEAM_ID ?= MM233FKU38
export SCREEN_PRIVACY_SIGNING_IDENTITY SCREEN_PRIVACY_NOTARY_PROFILE SPARKLE_KEY_ACCOUNT

.PHONY: help version test build run release-check setup-notary release-build release-notarize release-dmg release-appcast release-publish release release-dry-run

help: ## Show all commands and the full release process
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9._-]+:.*## / {printf "  %-19s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nFull release: release-check -> test -> release-build -> release-notarize -> release-dmg -> release-appcast -> release-publish\n'
	@printf 'Use make release for the complete sequence, or run steps separately with RELEASE_DIR=<same-directory>.\n'
	@printf 'Current version: $(APP_VERSION) (build $(APP_BUILD)); default notary profile: $(SCREEN_PRIVACY_NOTARY_PROFILE).\n'

version: ## Show the app version, build, and release tag
	@printf 'Screen Privacy $(APP_VERSION) (build $(APP_BUILD)); tag v$(APP_VERSION)\n'

test: ## Run Swift tests and release-tool guard tests
	swift test $(if $(filter true,$(SWIFTPM_DISABLE_SANDBOX)),--disable-sandbox,)
	./scripts/test-release-tools.sh

build: ## Build a new locally signed .app in artifacts/local
	./scripts/build-local-app.sh

run: ## Build and open a new local .app
	@set -eu; \
	output_dir="$(CURDIR)/artifacts/local/run-$$(uuidgen)"; \
	./scripts/build-local-app.sh "$$output_dir"; \
	open "$$output_dir/Screen Privacy.app"

release-check: ## Check Git, Developer ID, Sparkle key, notary profile, and GitHub access
	./scripts/check-release-setup.sh

setup-notary: ## Store notary credentials in Keychain (APPLE_ID=you@example.com)
	APPLE_ID="$(APPLE_ID)" APPLE_TEAM_ID="$(APPLE_TEAM_ID)" ./scripts/setup-notary-profile.sh

release-build: ## Build and Developer ID sign a universal app (RELEASE_DIR=...)
	./scripts/build-release-app.sh --output-dir "$(RELEASE_DIR)"

release-notarize: ## Notarize/staple app and create final signed ZIP
	./scripts/notarize-release.sh "$(RELEASE_DIR)"

release-dmg: ## Create, sign, notarize, and staple installable DMG
	./scripts/create-dmg.sh "$(RELEASE_DIR)"

release-appcast: ## Generate EdDSA-signed Sparkle feed from final notarized DMG
	./scripts/generate-appcast.sh "$(RELEASE_DIR)"

release-publish: ## Verify and upload DMG/ZIP/feed to public GitHub Release
	./scripts/publish-github-release.sh "$(RELEASE_DIR)"

release: ## Run every required release step and publish on success
	@$(MAKE) release-check RELEASE_DIR="$(RELEASE_DIR)"
	@$(MAKE) test RELEASE_DIR="$(RELEASE_DIR)"
	@$(MAKE) release-build RELEASE_DIR="$(RELEASE_DIR)"
	@$(MAKE) release-notarize RELEASE_DIR="$(RELEASE_DIR)"
	@$(MAKE) release-dmg RELEASE_DIR="$(RELEASE_DIR)"
	@$(MAKE) release-appcast RELEASE_DIR="$(RELEASE_DIR)"
	@$(MAKE) release-publish RELEASE_DIR="$(RELEASE_DIR)"

release-dry-run: ## Print the full release command sequence without executing it
	@$(MAKE) -n release RELEASE_DIR="$(RELEASE_DIR)"
