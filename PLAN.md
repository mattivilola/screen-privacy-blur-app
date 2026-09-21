# Screen Privacy roadmap

## Scope

A small, dependency-free macOS menu bar app that estimates head direction using the camera, covers displays when attention is away, and uncovers them after steady attention returns. A tolerance control adjusts head-angle thresholds and the look-away delay; an optional custom message personalizes the cover.

The app processes frames locally, never records them, and makes no network requests. It is a convenience privacy layer, not authentication or a replacement for the macOS lock screen.

## Implemented

- Native Swift 6 / AppKit app for macOS 14 and later.
- AVFoundation capture and Vision head-pose analysis with bounded serial processing.
- Attention hysteresis, debounce, conservative recovery, and missing-frame protection.
- Menu bar controls, camera permission onboarding, display covers, and lifecycle handling.
- Persistent tolerance setting.
- Locally saved custom message with a 120-character limit, three-line maximum, and a centered overlay bounded by one third of each display.
- Attention regression tests and release-signing guard tests.
- Local app builds, universal release builds, signing, notarization, ZIP/DMG packaging, and CI workflows.
- MIT license, contribution guidance, and privacy limitations.
- Temporary app icon and reproducible icon packaging.

## Before a stable binary release

- Complete the [hardware validation checklist](docs/VALIDATION.md) across supported macOS versions, camera configurations, and display arrangements.
- Measure active CPU, memory, energy use, false triggers, and response times on real hardware.
- Verify full-screen apps, Spaces, menu access, screen sharing behavior, and sleep/wake transitions.
- Validate Developer ID signing, notarization, stapling, and a quarantined download on another Mac.
- Replace the temporary icon with dedicated project artwork.

Keep the product simple: no cloud processing, accounts, telemetry, updater, or additional preferences without a demonstrated need.
