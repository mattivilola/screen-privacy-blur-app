# Screen Privacy

[![CI](https://github.com/mattivilola/screen-privacy-blur-app/actions/workflows/ci.yml/badge.svg)](https://github.com/mattivilola/screen-privacy-blur-app/actions/workflows/ci.yml)

<img src="Assets/AppIcon.png" width="128" alt="Temporary ILO apps icon">

A small native macOS menu bar app that covers your displays when you look away and uncovers them when you face the camera again.

**Early prototype.** Camera accuracy, display coverage, and energy use need hardware validation before relying on it. Requires macOS 14 or later and a camera. Written in Swift 6 with AppKit, AVFoundation, and Vision; no third-party dependencies.

## Use

1. Build and open the app using the commands below.
2. Choose **Enable protection** and allow camera access.
3. Face the camera. The screen uncovers after steady attention is detected.
4. Use the eye icon in the menu bar to pause protection or quit.

Choose **Preview for 5 seconds** to see the blur, logo, and message without looking away. It also works while protection is paused, without starting the camera or asking for permission. Selecting it again restarts the five-second preview. Afterward, the app returns to normal protection behavior; an active cover stays on if attention detection still requires it.

**Tolerance** controls how much head movement is allowed and how long the app waits before covering. Moving it right makes detection more forgiving.

Choose **Custom message…** to set the text beneath the logo. It is limited to 120 characters and displayed in at most three lines, with automatic font sizing. The centered overlay stays within one third of each screen's width and height; unusually wide text is truncated if needed to keep it readable. Leave the message blank to show “Screen Privacy”.

Both preferences are stored locally and persist between launches. Protection also resumes on subsequent launches if it was enabled and camera permission remains available.

Keep your camera close to your screen's center. This app estimates head direction relative to the camera, not your eye gaze or which monitor you are reading. Looking only with your eyes may not trigger the cover. There is no camera picker or calibration flow.

## Build

Install Xcode with the Swift 6 toolchain and select it with `xcode-select`, then clone the source:

```sh
git clone https://github.com/mattivilola/screen-privacy-blur-app.git
cd screen-privacy-blur-app
```

Build and launch locally:

```sh
make run
```

This builds an ad-hoc signed app and opens it in the menu bar. Quit an already running copy before launching an updated build.

Build and test separately:

```sh
swift test
./scripts/test-release-tools.sh
./scripts/build-local-app.sh
```

The script prints the path of a locally signed `.app`. Open that bundle so macOS can associate camera permission with the application. `swift run` is not the recommended camera workflow. Local ad-hoc signatures are for development; public downloads should be Developer ID signed and notarized.

See [release instructions](docs/RELEASING.md) for universal builds, signing, notarization, ZIP/DMG packaging, and GitHub artifacts. Signing credentials belong in your Keychain, not this repository.

## Privacy and limitations

- Camera frames are analyzed in memory on your Mac and discarded. No recording, uploads, analytics, accounts, or network requests.
- Camera permission is required. The camera indicator remains visible while capture is active. Microphone, screen recording, and Accessibility permissions are not requested.
- This is **not authentication or a screen lock**. Any single person facing the camera can uncover the screen. Face detection can miss bystanders, fail in low light, or be fooled by an image.
- Multiple detected faces, invalid pose information, and camera errors cannot uncover a covered screen. Brief attention loss is debounced; lack of fresh camera frames triggers a cover after about 1.5 seconds.
- The overlay uses macOS background blur with the app icon and your message in a centered, rounded panel on each display. Its appearance follows the system theme and accessibility settings. Blur can leave content recognizable. Menu bar and higher-level system UI may remain visible. Full-screen apps, Spaces, Mission Control, and display changes require verification on your setup.
- The overlay is mouse-transparent: applications keep running and keyboard/mouse input still reaches them. Pause from the menu bar before interacting with a covered display. It is not a guarantee of concealment in screenshots or screen sharing.
- Capture stops on workspace sleep/inactivity and screen sleep. Supplemental macOS lock/unlock notifications are used as a best-effort optimization, not as a security boundary.

Use the macOS lock screen when you need access control or dependable concealment.

## Performance approach

The app requests 640×480 capture (or the low preset as a fallback) and a 4 FPS camera stream where supported, then runs face detection at most roughly 4 times per second on a serial utility queue. Late frames are dropped. No frame backlog, screen capture loop, or per-frame UI redraw is needed; covers are reused until the display arrangement changes. Camera hardware and the compositor still consume power. CPU, memory, and battery claims have not yet been measured.

The detection pipeline deliberately uses face rectangles with head angles instead of detailed eye landmarks or a separate neural model. Tolerance adjusts yaw (12–35°), pitch (12–30°), and look-away delay (0.35–1.25 seconds). Returning requires a narrower head-angle range and 0.35 seconds of steady attention, quantized by the frame cadence.

## Development

- `Sources/AttentionCore`: deterministic attention policy and timing.
- `Sources/OverlayUI`: message editing and responsive overlay layout.
- `Sources/ScreenPrivacy`: menu bar app, camera pipeline, display covers.
- `Tests/AttentionCoreTests`: regression tests without camera access.
- [PLAN.md](PLAN.md): implementation scope and progress.
- [Manual validation](docs/VALIDATION.md): hardware checks and performance procedure.
- [App icon](docs/ICON.md): source artwork and macOS icon rebuild tooling.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and bug-report guidance and [SECURITY.md](SECURITY.md) for private vulnerability reporting.

## License

[MIT](LICENSE). Anyone may use, modify, and distribute the source under those terms.
