# Contributing

Bug reports and small, focused pull requests are welcome. Screen Privacy is an early prototype; please describe the behavior you observed without assuming it provides authentication or guaranteed concealment.

For bug reports, include your macOS version, Mac architecture, camera type, display arrangement, and reproduction steps. Do not attach camera images, private screen contents, credentials, or unredacted diagnostic logs.

## Develop and verify

Use Xcode with Swift 6 and macOS 14 or later. No third-party packages are required.

```sh
swift test
./scripts/test-release-tools.sh
./scripts/build-local-app.sh
```

For camera, lifecycle, or overlay changes, run the relevant checks in [docs/VALIDATION.md](docs/VALIDATION.md). Explain what was tested and what remains unverified in your pull request.

Keep camera processing local, work queues bounded, and the normal flow simple. Discuss significant dependencies, new preferences, or changes to privacy behavior in an issue first. Contributions are licensed under the repository's MIT license.
