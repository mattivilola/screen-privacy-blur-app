import AppKit
import AttentionCore

@MainActor
final class MotionSensorTestController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let session: MotionSensorTestSession
    private var observers: [NSObjectProtocol] = []
    private let content = MotionSensorTestView(frame: NSRect(x: 0, y: 0, width: 640, height: 770))
    private var timer: Timer?

    init(sensitivity: Double) {
        session = MotionSensorTestSession(sensitivity: sensitivity, monitor: HardwareMotionMonitor())
        let height = min(content.bounds.height, max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: height), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Motion sensor test — Screen Privacy"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: height))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = content
        scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
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
}
