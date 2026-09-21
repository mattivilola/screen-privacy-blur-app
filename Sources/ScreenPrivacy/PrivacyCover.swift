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
            blur.material = .underWindowBackground
            blur.blendingMode = .behindWindow
            blur.state = .active
            addBranding(to: blur)
            panel.contentView = blur
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    private func addBranding(to blur: NSVisualEffectView) {
        let icon = NSImageView()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            icon.image = NSImage(contentsOf: url)
        } else {
            icon.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "Screen Privacy")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let branding = NSStackView(views: [icon, title])
        branding.orientation = .vertical
        branding.alignment = .centerX
        branding.spacing = 14
        branding.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(branding)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
            branding.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            branding.centerYAnchor.constraint(equalTo: blur.centerYAnchor)
        ])
    }
}
