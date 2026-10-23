import AppKit
import Testing
@testable import OverlayUI

@MainActor
struct AlarmPresentationTests {
    @Test func alarmAlternatesOpaqueRedAndWhiteAndBannerStaysAtTop() throws {
        let view = AlarmPresentationView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = false
        view.status = "Alarm armed · monitoring movement"
        view.sounding = true
        let red = try render(view)
        #expect(red.colorAt(x: 10, y: 10)!.redComponent > 0.7)
        #expect(red.colorAt(x: 10, y: 10)!.greenComponent < 0.5)
        view.whitePhase = true
        let white = try render(view)
        #expect(white.colorAt(x: 10, y: 10)!.greenComponent > 0.95)
        #expect(white.colorAt(x: 10, y: 10)!.alphaComponent > 0.99)
        view.sounding = false
        let banner = try render(view)
        #expect(banner.colorAt(x: 10, y: 40)!.alphaComponent > 0.75)
        if let path = ProcessInfo.processInfo.environment["SCREEN_PRIVACY_RENDER_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, image) in [("alarm-red", red), ("alarm-white", white), ("alarm-banner", banner)] {
                try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
    }
    @Test func reducedMotionKeepsTheAlarmVisibleWithoutFlashing() throws {
        let view = AlarmPresentationView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = true
        view.status = "Movement detected"
        view.sounding = true
        view.whitePhase = true
        let image = try render(view)
        #expect(image.colorAt(x: 10, y: 10)!.redComponent > 0.7)
        #expect(image.colorAt(x: 10, y: 10)!.greenComponent < 0.5)
        #expect(view.accessibilityLabel() == "Alarm sounding")
    }
    private func render(_ view: AlarmPresentationView) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
