import AppKit
import XCTest
@testable import OverlayUI

@MainActor
final class InterfacePresentationTests: XCTestCase {
    func testReadablePresentationsInSystemAppearances() throws {
        // These renders exercise real native views. They are reviewed visually;
        // a successful render alone is not an accessibility or usability claim.
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua),
                                      ("contrast-light", .accessibilityHighContrastAqua), ("contrast-dark", .accessibilityHighContrastDarkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let menu = InterfaceCanvas(frame: NSRect(x: 0, y: 0, width: MenuDashboard.width, height: 438))
            let header = StatusHeaderView()
            header.update(title: "Screen is covered", subtitle: "Built-in camera", tone: .caution, symbolName: "eye.slash")
            let meter = AttentionMeterView(recoveryFraction: 0.8)
            meter.update(AttentionMeterReading(statusText: "Looking at screen", tone: .good, ratio: 0.25,
                                              detail: "Look away to try the screen cover"))
            let slider = SettingSliderView(title: "Head movement", leftLabel: "Stricter", rightLabel: "More forgiving",
                accessibilityLabel: "Head movement tolerance", toolTip: "Allows natural head movement", value: 0.5,
                describe: { _ in SettingReading(valueText: "50%", tierName: "Balanced", tone: .balanced,
                                                detail: "Room for small, natural head movements") }, onChange: { _ in })
            let alarm = MenuNoteView(text: "Alarm mode is off. Face the screen, then look away to arm.")
            let siren = MenuNoteView(text: "The siren test temporarily uses maximum built-in speaker volume. Your previous settings return afterward.")
            var y: CGFloat = 8
            for child in [header, meter, slider, alarm, siren] {
                child.frame.origin = NSPoint(x: 0, y: y)
                menu.addSubview(child); y += child.frame.height + 8
            }
            menu.frame.size.height = y + 8
            let explanation = ExplanationView(items: [
                ExplanationItem(symbol: "camera", title: "Camera stays on this Mac", message: "The camera runs while protection is on. Frames are processed here and never saved."),
                ExplanationItem(symbol: "rectangle.on.rectangle", title: "A frozen, blurred cover", message: "Allow Screen Recording for a blurred snapshot. Without it, the cover is opaque."),
                ExplanationItem(symbol: "hand.raised", title: "You stay in control", message: "Pause from the menu bar or press ⌥⌘P. Anyone facing the camera can uncover the screen; this is not a lock.")
            ])
            let message = MessageEditor().makeAccessoryView()
            for (suffix, view) in [("dashboard", menu), ("welcome", explanation), ("message", message)] {
                try render(view, appearance: appearance, name: name + "-" + suffix)
            }
        }
    }

    private func render(_ view: NSView, appearance: NSAppearance, name: String) throws {
        let canvas = InterfaceCanvas(frame: NSRect(x: 0, y: 0, width: view.frame.width + 40, height: view.frame.height + 40))
        view.frame.origin = NSPoint(x: 20, y: 20)
        canvas.addSubview(view); canvas.appearance = appearance
        canvas.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        appearance.performAsCurrentDrawingAppearance { canvas.cacheDisplay(in: canvas.bounds, to: rep) }
        if let directory = ProcessInfo.processInfo.environment["SCREEN_PRIVACY_RENDER_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
        }
    }
}

@MainActor
private final class InterfaceCanvas: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); bounds.fill() }
}
