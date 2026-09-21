import AppKit
import Testing
@testable import OverlayUI

@MainActor
struct CoverLayoutTests {
    @Test func contentFitsCenteredThirdOfEachDisplay() {
        let screens: [NSSize] = [NSSize(width: 800, height: 600), NSSize(width: 1440, height: 900),
                                NSSize(width: 1920, height: 1080), NSSize(width: 900, height: 1440),
                                NSSize(width: 3840, height: 2160)]
        let messages = ["", "Back in five minutes", String(repeating: "A long privacy message. ", count: 8),
                        String(repeating: "W", count: 120), String(repeating: "🔒👨‍👩‍👧‍👦", count: 60)]
        for screen in screens {
            for message in messages {
                let layout = CoverLayout(screenSize: screen, message: message)
                #expect(layout.frame.width <= screen.width / 3 + 0.01)
                #expect(layout.frame.height <= screen.height / 3 + 0.01)
                #expect(abs(layout.frame.midX - screen.width / 2) < 0.01)
                #expect(abs(layout.frame.midY - screen.height / 2) < 0.01)
                #expect(layout.lineCount > 0 && layout.lineCount <= 3)
                let bounds = NSRect(origin: .zero, size: layout.frame.size)
                #expect(bounds.contains(layout.iconFrame))
                #expect(bounds.contains(layout.textFrame))
                #expect(layout.iconFrame.minY > layout.textFrame.maxY)
                #expect(layout.font.pointSize >= 12)
            }
        }
    }

    @Test func longerTextUsesSmallerFontWithoutGrowingPastBounds() {
        let screen = NSSize(width: 1440, height: 900)
        let short = CoverLayout(screenSize: screen, message: "Screen Privacy")
        let long = CoverLayout(screenSize: screen, message: String(repeating: "Wide wording ", count: 10))
        #expect(long.font.pointSize < short.font.pointSize)
        #expect(long.frame.height <= screen.height / 3)
        #expect(long.lineCount <= 3)
    }
}
