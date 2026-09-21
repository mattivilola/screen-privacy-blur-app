# Screen Privacy roadmap

## Scope

A small, dependency-free macOS menu bar app that estimates head direction using the camera, covers displays when attention is away, and uncovers them after steady attention returns. A tolerance control adjusts head-angle thresholds and the look-away delay; an optional custom message personalizes the cover. A cover immediately presents an opaque neutral surface, then may replace it with one frozen, blurred snapshot per display when Screen Recording permission is available.

The app processes camera frames locally, makes no network requests, and does not capture screen audio, video, or a continuous screen feed. A permitted cover snapshot is a screen image, so the product must not claim that it never records or captures screens. Raw screen images are transient memory only; only the blurred result is displayed and it is released when the cover is removed. A frozen cover prevents later messages and window changes from appearing beneath a live blur, avoids a washed-out material appearance, and limits captures to cover transitions. The initial snapshot may still be recognizable through blur. It is a convenience privacy layer, not authentication or a replacement for the macOS lock screen.

## Implemented

- Native Swift 6 / AppKit app for macOS 14 and later.
- AVFoundation capture and Vision head-pose analysis with bounded serial processing.
- Attention hysteresis, debounce, conservative recovery, and missing-frame protection.
- Menu bar controls, camera permission onboarding, display covers, and lifecycle handling.
- One-shot CoreGraphics window-list snapshots per display, captured below and excluding this app's cover window: longest edge capped at 1600 pixels, Gaussian blur near 12 screen points, and no white tint.
- Opaque neutral cover shown immediately and retained as the fallback for missing permission or capture failure; macOS may blank protected/DRM content inside a snapshot.
- Screen Recording requested only through **Screen Capture Permission…**, enable protection, or Preview; relaunch guidance when macOS requires it after a grant.
- Snapshot lifecycle clears images on uncover, pause, sleep, lock, wake, and display changes, with no capture while suspended or locked.
- Persistent blur-level slider that re-blurs a visible cover once the drag settles, mapping the strength to a Gaussian radius between 6 and 18 screen points.
- Persistent tolerance and blur level settings.
- Locally saved custom message with a 120-character limit, three-line maximum, and a centered overlay bounded by one third of each display.
- Attention regression tests and release-signing guard tests.
- Local app builds, universal release builds, signing, notarization, ZIP/DMG packaging, and CI workflows.
- MIT license, contribution guidance, and privacy limitations.
- Temporary app icon and reproducible icon packaging.

## Before a stable binary release

- Complete the [hardware validation checklist](docs/VALIDATION.md) across supported macOS versions, camera configurations, and display arrangements.
- Measure active CPU, memory, energy use, false triggers, and response times on real hardware.
- Verify full-screen apps, Spaces, menu access, screen sharing behavior, and sleep/wake transitions.
- Perform the snapshot-specific [manual checks](docs/VALIDATION.md): delayed or cancelled completion, permission revocation and relaunch, protected/DRM content, static covered content, all display arrangements, and no stale image after lifecycle changes.
- Measure cover creation latency, memory, CPU, and energy on real hardware before making performance claims.
- Validate Developer ID signing, notarization, stapling, and a quarantined download on another Mac.
- Replace the temporary icon with dedicated project artwork.

Keep the product simple: no cloud processing, accounts, telemetry, updater, or additional preferences without a demonstrated need.
