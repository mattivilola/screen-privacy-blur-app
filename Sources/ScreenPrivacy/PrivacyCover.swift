import AppKit
import OverlayUI
import SnapshotCore

@MainActor
final class PrivacyCover {
    private var panels: [NSPanel] = []
    private var brandingViews: [CoverBrandingView] = []
    private var imageViews: [CGDirectDisplayID: NSImageView] = [:]
    private let snapshots = FrozenSnapshotCapture()
    private var captureTask: Task<Void, Never>?
    private var captureID = UUID()
    private var blurReplacementPending = false
    private(set) var isVisible = false
    var captureAllowed = true {
        didSet {
            guard captureAllowed != oldValue else { return }
            discardSnapshot()
            if captureAllowed { refreshSnapshotIfNeeded() }
        }
    }
    var message = "" {
        didSet { brandingViews.forEach { $0.updateMessage(message) } }
    }
    /// 0 hides details behind heavy blur; 1 keeps large shapes but lets short text stay legible.
    var blurStrength = 0.5 {
        didSet {
            guard blurStrength != oldValue else { return }
            scheduleBlurReplacement()
        }
    }
    private var blurReplacement: Timer?

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            if panels.isEmpty {
                rebuild()
            } else {
                panels.forEach {
                    $0.alphaValue = 0
                    $0.orderFrontRegardless()
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    panels.forEach { $0.animator().alphaValue = 1.0 }
                }
                refreshSnapshotIfNeeded()
            }
        } else {
            discardSnapshot()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panels.forEach { $0.animator().alphaValue = 0.0 }
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isVisible else { return }
                    self.panels.forEach { $0.orderOut(nil) }
                }
            })
        }
    }

    func rebuild() {
        discardSnapshot()
        let oldPanels = panels
        panels = []
        brandingViews = []
        imageViews = [:]
        // Leave old covers visible until the new neutral covers have been ordered
        // front, so changing displays does not deliberately expose the desktop.
        defer { oldPanels.forEach { $0.orderOut(nil) } }
        guard isVisible else { return }
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.alphaValue = 0

            let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            let imageView = NSImageView(frame: content.bounds)
            imageView.imageScaling = .scaleAxesIndependently
            imageView.setAccessibilityElement(false)
            content.addSubview(imageView)
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                imageViews[id.uint32Value] = imageView
            }
            let branding = CoverBrandingView(screenSize: screen.frame.size, message: message, icon: appIcon)
            content.addSubview(branding)
            brandingViews.append(branding)
            panel.contentView = content
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panels.forEach { $0.animator().alphaValue = 1.0 }
        }
        refreshSnapshotIfNeeded()
    }

    func refreshSnapshotIfNeeded() {
        guard isVisible, captureAllowed, captureTask == nil,
              imageViews.values.allSatisfy({ $0.image == nil }),
              CGPreflightScreenCaptureAccess() else { return }
        startCapture()
    }

    /// Slider drags fire continuously; debounce so one settled re-capture replaces
    /// the frozen images in place instead of flickering the cover to neutral.
    private func scheduleBlurReplacement() {
        blurReplacement?.invalidate()
        guard isVisible, captureAllowed, CGPreflightScreenCaptureAccess() else { return }
        let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.replaceSnapshots() }
        }
        blurReplacement = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func replaceSnapshots() {
        blurReplacement = nil
        guard isVisible, captureAllowed, CGPreflightScreenCaptureAccess() else { return }
        // Never cancel into FrozenSnapshotCapture's single-request guard. Let the
        // current capture finish, then replace it with the latest requested radius.
        guard captureTask == nil else {
            blurReplacementPending = true
            return
        }
        startCapture()
    }

    private func startCapture() {
        let displays = NSScreen.screens.compactMap { screen -> SnapshotDisplay? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let panel = panels.first(where: { $0.frame.equalTo(screen.frame) }) else { return nil }
            return SnapshotDisplay(id: id.uint32Value, pointWidth: screen.frame.width, pointHeight: screen.frame.height,
                                   screenRect: screen.frame, coverWindowID: CGWindowID(panel.windowNumber),
                                   blurStrength: blurStrength)
        }
        let token = UUID()
        captureID = token
        let snapshots = snapshots
        captureTask = Task { [weak self] in
            let images = (try? await snapshots.capture(displays: displays)) ?? [:]
            guard let self, !Task.isCancelled, self.isVisible, self.captureAllowed, self.captureID == token else { return }
            for (id, image) in images {
                guard let view = self.imageViews[id] else { continue }
                view.image = NSImage(cgImage: image, size: view.bounds.size)
            }
            self.captureTask = nil
            if self.blurReplacementPending {
                self.blurReplacementPending = false
                self.replaceSnapshots()
            }
        }
    }

    private func discardSnapshot() {
        blurReplacement?.invalidate()
        blurReplacement = nil
        blurReplacementPending = false
        captureID = UUID()
        captureTask?.cancel()
        captureTask = nil
        // Release the frozen image at uncover, suspension, or display changes.
        imageViews.values.forEach { $0.image = nil }
    }

    private var appIcon: NSImage? {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            return NSImage(contentsOf: url)
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        if let image = NSImage(named: "AppIcon") {
            return image
        }
        let localPath = "Assets/AppIcon.png"
        if FileManager.default.fileExists(atPath: localPath) {
            return NSImage(contentsOfFile: localPath)
        }
        return NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)
    }
}
