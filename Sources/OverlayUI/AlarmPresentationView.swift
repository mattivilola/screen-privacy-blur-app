import AppKit

/// Drawn in the existing cover window; never receives input or obscures the menu bar.
@MainActor
public final class AlarmPresentationView: NSView {
    public var status: String? { didSet { needsDisplay = true } }
    public var sounding = false { didSet { needsDisplay = true } }
    public var whitePhase = false { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        guard let status else { return }
        if sounding {
            (whitePhase ? NSColor.white : NSColor.systemRed).setFill()
            bounds.fill()
            drawText("ALARM!", y: bounds.midY - 70, size: min(150, bounds.width / 7),
                     color: whitePhase ? .systemRed : .white)
            drawText("Movement detected · Disarm from the menu bar or press ⌥⌘P", y: bounds.midY - 120,
                     size: min(24, bounds.width / 40), color: whitePhase ? .black : .white)
        } else {
            let rect = NSRect(x: 0, y: bounds.height - 106, width: bounds.width, height: 90)
            NSColor.black.withAlphaComponent(0.8).setFill(); rect.fill()
            drawText("Alarm mode", y: bounds.height - 63, size: 30, color: .systemRed)
            drawText(status, y: bounds.height - 92, size: 17, color: .white)
        }
    }
    private func drawText(_ text: String, y: CGFloat, size: CGFloat, color: NSColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: NSRect(x: 18, y: y, width: max(1, bounds.width - 36), height: size * 1.5),
                               withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold),
                                                .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
