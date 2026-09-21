import AppKit
import OverlayUI

@MainActor
final class PrivacyCover {
    private var panels: [NSPanel] = []
    private var brandingViews: [CoverBrandingView] = []
    private(set) var isVisible = false
    var message = "" {
        didSet {
            brandingViews.forEach { $0.updateMessage(message) }
        }
    }

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
        brandingViews.removeAll()
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
            // Under-window material heavily flattens colors on macOS and can
            // resemble a solid gray cover. Full-screen material keeps the live
            // desktop recognizable through the system-composited blur.
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            let branding = CoverBrandingView(screenSize: screen.frame.size, message: message, icon: appIcon)
            blur.addSubview(branding)
            brandingViews.append(branding)
            panel.contentView = blur
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    private var appIcon: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: url)
        }
        return NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
    }
}
