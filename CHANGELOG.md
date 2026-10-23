# Screen Privacy releases

## 0.4.0

- Make the menu dashboard easier to scan with larger status text, clear camera guidance, and plain-language setting labels. Exact angles, delays, and movement thresholds remain available on hover.
- Guide the silent motion sensor test through keeping still and lifting or tilting the Mac. Show a live movement meter, with raw readings and graphs under Sensor details. Add clear retry, test-again, and Done actions.
- Simplify welcome, permission, and About dialogs with native icons and shorter explanations. Add a live preview to the screen-message editor.
- Keep the alarm solid red when macOS Reduce Motion is enabled, and improve accessibility labels without announcing every flashing frame.

## 0.3.1

- Add a silent **Test motion sensor…** window with raw acceleration, movement/peak values, valid report rate/count, freshness, alarm threshold, and a live graph.
- Calibrate, then verify a sustained physical-sensor trigger using the real alarm policy without camera input, sound, or flashing. Screen protection pauses during the test and resumes on close; Alarm mode remains disarmed.
- Activate the dedicated SPU accelerometer with an interval-only request, durable recovery record, exclusive lease, explicit restoration, and a bounded no-readings failure. No administrator permission is needed on the tested Mac.
- Make fresh, calibrated physical readings primary. Add native-rate acceleration RMS and frozen-reference tilt detection with physical sensitivity thresholds; camera movement remains a fallback. The silent diagnostic runs the same policy and displays RMS/tilt thresholds.
- Live testing confirmed roughly 796 reports/s, successful interval restoration, and the owner's movement trials; broad hardware and environment tuning remains pending.

## 0.3.0

- Optional Alarm mode starts an adjustable countdown after you look away, then monitors camera movement. A red Alarm mode banner appears on the blurred cover; returning faces cannot disarm it.
- Movement triggers a locally generated, looping siren through verified built-in speakers, plus a red/white ALARM display. Built-in speaker output is temporarily set to maximum; Siren level controls loudness. Disarm, test completion, and quit restore prior volume and mute.
- Includes movement sensitivity, a 3–30 second arm countdown, a three-second siren/flashing test, and an optional closed-lid/camera-loss tamper trigger with a short grace period.
- Detects compatible built-in accelerometers and uses their readings when normal access works. Camera detection remains available when hardware is absent or inaccessible.
- Keeps the display awake during Alarm mode. Optional closed-lid operation uses an approved, signed helper with battery/heat guards and journaled crash recovery, adapted from Nomad Dashboard.

Alarm mode is a local deterrent, not a lock or a theft guarantee. Camera faults and moving backgrounds may trigger it. Closed-lid operation needs helper approval; it does not make the built-in camera usable behind a closed lid. Automatic locking and a PIN are not included.

## 0.2.0

- Automatic lighting correction adapts shadow lift and highlight reduction for indoor light, sun, and shaded faces against bright backgrounds. Cameras use continuous exposure and white balance where supported, with 720p capture when available.
- Unclear frames can try both light corrections immediately, and confident face rectangles without usable head direction now receive a retry too.
- Status text explicitly says the screen is covered and distinguishes missing face detection from camera obstruction.

## 0.1.1

- Redesigned menu with a status header, grouped sections, and icons.
- New Live check meter shows your head direction against the look-away limit, in green, orange, or red.
- Tolerance and Blur level sliders now show a value, a color tier, and what the setting means in practice.
- Better detection in bright sun and backlight: a frame with no clear face is re-checked once with adjusted exposure, and the menu says when light is the likely problem.
- A single unclear face now uses the look-away delay instead of covering immediately, which reduces flicker from brief detection dropouts. Several faces still cover immediately.

## 0.1.0

First public release of Screen Privacy for macOS 14 and later.

- Covers your displays when local camera analysis detects that you look away, and uncovers them after steady attention returns.
- Shows a frozen, locally blurred image of each display when Screen Recording permission is granted. Later screen changes stay hidden; an opaque cover remains available when capture is unavailable.
- Includes a menu bar preview, head-position tolerance, blur level, optional message, camera selection, a global protection shortcut, and launch at login.
- Provides a signed update feed through Sparkle and a drag-to-Applications DMG.

This is an early privacy convenience tool. A frozen image may remain recognizable, and another person facing the camera may uncover the display. Lock your Mac for access control.
