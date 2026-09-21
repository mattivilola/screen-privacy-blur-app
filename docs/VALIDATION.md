# Validation

Automated tests exercise the attention state machine, not real-world gaze accuracy. A successful build or launch is not camera, battery, or notarization proof.

## Hardware checklist before a public binary release

- First launch: choose Later; no camera indicator and no Screen Recording prompt. Enable and grant camera access; cover initially appears, then clears after steady attention. Confirm Screen Recording is requested only after selecting **Screen Capture Permission…**, enabling protection, or starting Preview. Denied/restricted camera and Screen Recording permissions each have an understandable recovery flow.
- Turn left/right, look down, leave the chair, and return. Test both tolerance extremes, ordinary blinks, glasses, dim light, camera above/below the display, and reading another monitor. Record false cover/uncover events.
- Test no face, more than one face, and another person replacing the original user. The last case can uncover by design: identity is not verified.
- Pause while covered: cover disappears and camera stops. Quit restores normal display. Relaunch with protection enabled and paused.
- Preview for five seconds while paused and confirm the camera stays off but Screen Recording permission is requested if needed for the preview snapshot. Confirm the cover disappears afterward. While protection is active, verify looking toward the camera does not end the preview early, expiration restores the current attention state, and looking away still keeps the cover on. Repeat Preview to restart its timer; pause, sleep, lock, or cancel before capture completion to cancel the request and avoid showing a late/stale image.
- Unplug/reconnect an external camera; compete for the camera with a call app; test runtime errors and revoked permission. Stale input must not leave the display uncovered indefinitely. Pause then enable to retry failed capture.
- Sleep/wake displays and the Mac; lock/unlock and switch users. Check camera and screen capture stop while suspended or locked, no screen image is captured in those states, and stale attention or stale snapshots cannot uncover or redraw a display after resume.
- Test all connected monitors, hot-plug, arrangement/resolution changes, full-screen apps, Spaces, Stage Manager, Mission Control, auto-hidden menu bar, and Reduce Transparency. Confirm the menu bar pause command is reachable. After a display change, confirm old per-display snapshots are discarded and a fresh cover never assigns the wrong display's image.
- Confirm the cover does not steal focus; document any windows or system UI above it. Test screen sharing/recording separately; do not claim protection there based on local display checks.
- With Screen Recording granted, cover each display and verify there is one frozen snapshot per display: video, clocks, and moving windows behind it remain static until uncovering. Confirm it is scaled to a reasonable low-resolution blur, has a Gaussian-style blur of about 12 screen points, has no white tint, and centers the app icon/name on each display in light and dark appearances. The raw image must not be visible in the cover, retained after uncovering, written to files, or sent over the network.
- Confirm the intended relative privacy benefit with a controlled check: start a cover, then create a new message or move a window behind it. The later change must not appear until uncovering. Record whether text or window shapes from the initial snapshot remain recognizable; do not describe the result as a lock, authentication, or a general concealment guarantee.
- Deny or revoke Screen Recording permission in System Settings, then cover and Preview. Confirm the opaque neutral fallback appears without a retry loop or a live/partial screen image. Re-grant permission and follow the app's relaunch guidance if macOS requires it. Test a DRM/protected-video window and TCC capture failure: macOS may blank protected regions within a snapshot, while a failed screenshot must keep the opaque fallback. Do not claim protected content was captured or blurred.
- Edit the custom message, save/cancel it, and relaunch. Test blank text, pasted long text, emoji, input-method composition, and very wide characters. Verify the live character count, three-line limit, and centered card bounds on small, large, and portrait displays. Saving while covered should update the message without briefly removing the cover.
- Verify VoiceOver describes the menu item, status, and tolerance slider; operate the menu with the keyboard.

## Energy and responsiveness

Use the optimized release build on a known Mac and record macOS version, camera, display count, and power source. Warm up for one minute, then collect at least five minutes each with protection paused, active/uncovered, opaque fallback covered, and snapshot covered. Compare Activity Monitor CPU, memory, and Energy Impact and use Instruments Time Profiler/Energy tooling for any sustained cost. Measure the time to produce covers for one and several displays and confirm there is no continuing screen-capture activity after completion. A camera with a minimum capture rate above 4 FPS can consume more power even though analysis remains throttled.

Measure look-away and return latency at both tolerance extremes. Measure dropped/stalled input recovery. Repeat with a video playing behind the cover to reveal compositor costs. Treat these as observed measurements for that setup, not universal guarantees.

## Distribution

Validate both architectures with `lipo`, inspect the bundle's plist/entitlements, verify the Developer ID signature and hardened runtime, and validate stapled app and DMG tickets. Test a quarantined download on another Mac. Local ad-hoc builds do not demonstrate Gatekeeper acceptance.

## Current verification

Automated checks can verify state transitions and image-lifecycle rules, but they do not establish macOS TCC behavior, protected-content behavior, real screen-capture performance, or visual quality. Record actual hardware results here before making those claims. Local ad-hoc app signatures may be verified separately.

Live camera checks, energy profiling, and credentialed distribution verification remain manual until recorded here with actual evidence. A successful CI run verifies source builds and tests; it does not establish real-world privacy or performance guarantees.
