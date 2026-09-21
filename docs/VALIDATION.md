# Validation

Automated tests exercise the attention state machine, not real-world gaze accuracy. A successful build or launch is not camera, battery, or notarization proof.

## Hardware checklist before a public binary release

- First launch: choose Later; no camera indicator. Enable and grant camera access; cover initially appears, then clears after steady attention. Denied/restricted permission has an understandable recovery flow.
- Turn left/right, look down, leave the chair, and return. Test both tolerance extremes, ordinary blinks, glasses, dim light, camera above/below the display, and reading another monitor. Record false cover/uncover events.
- Test no face, more than one face, and another person replacing the original user. The last case can uncover by design: identity is not verified.
- Pause while covered: cover disappears and camera stops. Quit restores normal display. Relaunch with protection enabled and paused.
- Preview for five seconds while paused and confirm the camera stays off and the cover disappears afterward. While protection is active, verify looking toward the camera does not end the preview early, expiration restores the current attention state, and looking away still keeps the cover on. Repeat preview to restart its timer; pause or sleep to cancel it.
- Unplug/reconnect an external camera; compete for the camera with a call app; test runtime errors and revoked permission. Stale input must not leave the display uncovered indefinitely. Pause then enable to retry failed capture.
- Sleep/wake displays and the Mac; lock/unlock and switch users. Check capture stops while suspended and resumes conservatively, without stale attention uncovering the display.
- Test all connected monitors, hot-plug, arrangement/resolution changes, full-screen apps, Spaces, Stage Manager, Mission Control, auto-hidden menu bar, and Reduce Transparency. Confirm the menu bar pause command is reachable.
- Confirm the cover does not steal focus; document any windows or system UI above it. Test screen sharing/recording separately; do not claim protection there based on local display checks.
- Check that the cover keeps underlying window shapes and colors visible through the blur, without a flat gray fill or added black tint, and centers the app icon/name on each display in light and dark appearances. The cover uses the native fullscreen material; under-window material can wash out the desktop. With Reduce Transparency enabled, macOS may substitute a more opaque material.
- Edit the custom message, save/cancel it, and relaunch. Test blank text, pasted long text, emoji, input-method composition, and very wide characters. Verify the live character count, three-line limit, and centered card bounds on small, large, and portrait displays. Saving while covered should update the message without briefly removing the cover.
- Verify VoiceOver describes the menu item, status, and tolerance slider; operate the menu with the keyboard.

## Energy and responsiveness

Use the optimized release build on a known Mac and record macOS version, camera, display count, and power source. Warm up for one minute, then collect at least five minutes each with protection paused, active/uncovered, and covered. Compare Activity Monitor CPU, memory, and Energy Impact and use Instruments Time Profiler/Energy tooling for any sustained cost. A camera with a minimum capture rate above 4 FPS can consume more power even though analysis remains throttled.

Measure look-away and return latency at both tolerance extremes. Measure dropped/stalled input recovery. Repeat with a video playing behind the cover to reveal compositor costs. Treat these as observed measurements for that setup, not universal guarantees.

## Distribution

Validate both architectures with `lipo`, inspect the bundle's plist/entitlements, verify the Developer ID signature and hardened runtime, and validate stapled app and DMG tickets. Test a quarantined download on another Mac. Local ad-hoc builds do not demonstrate Gatekeeper acceptance.

## Current verification

Ten attention regression tests, message normalization tests, responsive typography/layout tests, release-signing guard tests, native debug compilation, a universal arm64/x86_64 release build, and a camera-free launch smoke test have passed locally. Local ad-hoc app signatures have been verified.

Live camera checks, energy profiling, and credentialed distribution verification remain manual until recorded here with actual evidence. A successful CI run verifies source builds and tests; it does not establish real-world privacy or performance guarantees.
