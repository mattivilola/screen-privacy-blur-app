import AppKit

/// Drawn in the existing cover window; never receives input or obscures the menu bar.
@MainActor
public final class AlarmPresentationView: NSView {
    public var status: String? { didSet { needsDisplay = true; if status != oldValue { updateAccessibility() } } }
    public var sounding = false { didSet { needsDisplay = true; if sounding != oldValue { updateAccessibility() } } }
    public var whitePhase = false { didSet { needsDisplay = true } }
    /// nil follows macOS. An override keeps offscreen visual checks deterministic.
    public var reduceMotion: Bool? { didSet { needsDisplay = true } }

    private func updateAccessibility() {
        setAccessibilityElement(status != nil)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(sounding ? "Alarm sounding" : "Alarm mode")
        setAccessibilityValue(status.map { sounding ? "\($0). Disarm from the menu bar or press Option Command P." : $0 })
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let status else { return }
        if sounding {
            let showWhite = whitePhase && !(reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            (showWhite ? NSColor.white : NSColor.systemRed).setFill()
            bounds.fill()
            drawText("ALARM!", y: bounds.midY - 70, size: min(150, bounds.width / 7),
                     color: showWhite ? .systemRed : .white)
            drawText("Movement detected · Disarm from the menu bar or press ⌥⌘P", y: bounds.midY - 120,
                     size: min(24, bounds.width / 40), color: showWhite ? .black : .white)
        } else {
            let rect = NSRect(x: 0, y: bounds.height - 130, width: bounds.width, height: 114)
            NSColor.black.withAlphaComponent(0.8).setFill(); rect.fill()
            drawText("Alarm mode", y: bounds.height - 65, size: 28, color: .systemRed)
            drawText(status, y: bounds.height - 118, size: 17, color: .white, weight: .regular, height: 44)
        }
    }
    private func drawText(_ text: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight = .bold, height: CGFloat? = nil) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (text as NSString).draw(in: NSRect(x: 18, y: y, width: max(1, bounds.width - 36), height: height ?? size * 1.5),
                               withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
