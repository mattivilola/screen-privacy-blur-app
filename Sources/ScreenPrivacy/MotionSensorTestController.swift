import AppKit
import AttentionCore

@MainActor
final class MotionSensorTestController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let session: MotionSensorTestSession
    private var observers: [NSObjectProtocol] = []
    private let content: MotionSensorTestView
    private var timer: Timer?

    init(sensitivity: Double, protectionWasEnabled: Bool = false) {
        session = MotionSensorTestSession(sensitivity: sensitivity, monitor: HardwareMotionMonitor())
        content = MotionSensorTestView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 500),
            protectionWasEnabled: protectionWasEnabled
        )
        let maximumHeight = max(360, (NSScreen.main?.visibleFrame.height ?? 900) - 80)
        let height = min(maximumHeight, max(400, content.preferredHeight))
        let window = MotionSensorTestWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Motion sensor test — Screen Privacy"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: height))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = content
        scroll.autoresizingMask = [.width, .height]
        content.setFrameSize(NSSize(width: scroll.contentSize.width, height: content.preferredHeight))
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        content.onLayoutChange = { [weak self] in self?.resizeForContent() }
        session.onChange = { [weak self] in self?.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.pauseForSleep() }
            },
            workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.session.resumeAfterWake() }
            }
        ]
        for (button, action) in [(content.retryButton, #selector(retry)), (content.resetButton, #selector(reset)), (content.doneButton, #selector(done))] {
            button.target = self; button.action = action
        }
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            session.start()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    func invalidate() {
        timer?.invalidate(); timer = nil
        session.stop()
        session.onChange = nil
        content.onLayoutChange = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        onClose = nil
        window?.delegate = nil
        window?.orderOut(nil)
    }
    func windowWillClose(_ notification: Notification) {
        let completion = onClose
        invalidate()
        completion?()
    }
    func setSensitivity(_ value: Double) { session.setSensitivity(value) }
    @objc private func done() { close() }
    @objc private func reset() { session.reset() }
    @objc private func retry() { session.retry() }
    private func refresh() {
        content.update(diagnostic: session.diagnostic, monitorStatus: session.statusText, now: ProcessInfo.processInfo.systemUptime)
    }

    private func resizeForContent() {
        guard let window, let scroll = window.contentView as? NSScrollView else { return }
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 700)
        let maxHeight = max(360, visibleFrame.height - 80)
        let documentHeight = content.preferredHeight
        let desiredHeight = min(maxHeight, max(400, documentHeight))
        let priorFrame = window.frame
        window.setContentSize(NSSize(width: 620, height: desiredHeight))
        content.setFrameSize(NSSize(width: scroll.contentSize.width, height: documentHeight))
        var frame = window.frame
        frame.origin.x = priorFrame.midX - frame.width / 2
        frame.origin.y = min(visibleFrame.maxY - frame.height, max(visibleFrame.minY, priorFrame.maxY - frame.height))
        window.setFrame(frame, display: true, animate: false)
    }
}

@MainActor
private final class MotionSensorTestWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // Catch Escape at the window so focused controls cannot swallow the close action.
        if event.type == .keyDown && event.keyCode == 53 {
            performClose(nil)
            return
        }
        super.sendEvent(event)
    }
}
