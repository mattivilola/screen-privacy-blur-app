import AppKit

@MainActor
final class PrivacyCover {
    private var panels: [NSPanel] = []
    private(set) var isVisible = false

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if panels.isEmpty { rebuild() }
            else { panels.forEach { $0.orderFrontRegardless() } }
        } else {
            panels.forEach { $0.orderOut(nil) }
        }
    }

    func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        guard isVisible else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false

            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.appearance = NSAppearance(named: .darkAqua)
            let tint = NSView(frame: blur.bounds)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.90).cgColor
            blur.addSubview(tint)
            panel.contentView = blur
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }
}
