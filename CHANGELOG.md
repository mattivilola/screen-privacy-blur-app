# Screen Privacy releases

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
