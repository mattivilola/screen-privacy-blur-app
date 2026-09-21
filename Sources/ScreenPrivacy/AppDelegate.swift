import AppKit
import AVFoundation
import AttentionCore
import OverlayUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let defaults = UserDefaults.standard
    private let camera = CameraMonitor()
    private let cover = PrivacyCover()
    private var attention = AttentionState()
    private var statusItem: NSStatusItem!
    private let stateItem = NSMenuItem(title: "Paused", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Enable protection", action: #selector(toggle), keyEquivalent: "")
    private var enabled = false
    private var permissionPending = false
    private var sleeping = false
    private var sessionInactive = false
    private var screenLocked = false
    private var screensSleeping = false
    private var generation = UUID()
    private var lastFrame: TimeInterval?
    private var watchdog: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var suspended: Bool { sleeping || sessionInactive || screenLocked || screensSleeping }

    func applicationDidFinishLaunching(_ notification: Notification) {
        attention.tolerance = defaults.object(forKey: "tolerance") as? Double ?? 0.5
        cover.message = defaults.string(forKey: "coverMessage") ?? ""
        buildMenu()
        observeLifecycle()
        // This launch-only switch supports bundle smoke tests without camera access.
        if CommandLine.arguments.contains("--smoke-test") {
            print("Screen Privacy launched; menu ready; camera not started")
            NSApp.terminate(nil)
            return
        }
        if defaults.bool(forKey: "enabled") && AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            enabled = true
            resume()
        } else if !defaults.bool(forKey: "introduced") {
            defaults.set(true, forKey: "introduced")
            showIntroduction()
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let control = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 86))
        let title = NSTextField(labelWithString: "Tolerance")
        title.frame = NSRect(x: 18, y: 60, width: 210, height: 18)
        control.addSubview(title)
        let slider = NSSlider(value: attention.tolerance, minValue: 0, maxValue: 1,
                              target: self, action: #selector(changeTolerance(_:)))
        slider.frame = NSRect(x: 16, y: 31, width: 218, height: 24)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Head position and look-away tolerance")
        slider.toolTip = "Higher tolerance allows more head movement and waits longer before covering."
        control.addSubview(slider)
        let caption = NSTextField(labelWithString: "Stricter                           More forgiving")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: 18, y: 10, width: 215, height: 16)
        control.addSubview(caption)
        let setting = NSMenuItem()
        setting.view = control
        menu.addItem(setting)
        let message = NSMenuItem(title: "Custom message…", action: #selector(editMessage), keyEquivalent: "")
        message.target = self
        menu.addItem(message)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Screen Privacy…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Screen Privacy", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatus("Paused")
    }

    @objc private func toggle() {
        guard !permissionPending else { return }
        if enabled {
            enabled = false
            defaults.set(false, forKey: "enabled")
            stopCapture()
            cover.setVisible(false)
            updateStatus("Paused")
        } else {
            enableWithPermission()
        }
    }

    @objc private func editMessage() {
        let editor = MessageEditor()
        guard let message = editor.run(currentMessage: cover.message) else { return }
        defaults.set(message, forKey: "coverMessage")
        cover.message = message
    }

    private func enableWithPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            enabled = true
            defaults.set(true, forKey: "enabled")
            resume()
        case .notDetermined:
            permissionPending = true
            toggleItem.isEnabled = false
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionPending = false
                    self.toggleItem.isEnabled = true
                    if granted { self.enableWithPermission() }
                    else { self.updateStatus("Camera permission required") }
                }
            }
        default:
            updateStatus("Camera permission required")
            let alert = NSAlert()
            alert.messageText = "Allow camera access"
            alert.informativeText = "Enable Screen Privacy in System Settings → Privacy & Security → Camera, then enable protection again. Frames are processed locally and never saved."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func resume() {
        guard enabled else { return }
        stopCapture()
        _ = attention.unavailable()
        cover.setVisible(true)
        guard !suspended else {
            updateStatus("Protection suspended")
            return
        }
        updateStatus("Covered · checking attention")
        let token = generation
        lastFrame = ProcessInfo.processInfo.systemUptime
        camera.start { [weak self] event in
            Task { @MainActor in
                guard let self, self.enabled, !self.suspended, self.generation == token else { return }
                self.receive(event)
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFreshness() }
        }
        if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
    }

    private func stopCapture() {
        generation = UUID()
        watchdog?.invalidate()
        watchdog = nil
        lastFrame = nil
        camera.stop()
    }

    private func receive(_ event: CameraEvent) {
        switch event {
        case let .faces(faces, time):
            guard ProcessInfo.processInfo.systemUptime - time < 1 else {
                cover.setVisible(attention.unavailable())
                updateStatus("Covered · waiting for fresh frames")
                return
            }
            lastFrame = time
            cover.setVisible(attention.update(faces: faces, at: time))
            updateStatus(cover.isVisible ? "Covered · look toward the camera" : "Protection active")
        case let .unavailable(reason):
            cover.setVisible(attention.unavailable())
            updateStatus("Covered · \(reason)")
        }
    }

    private func checkFreshness() {
        guard enabled, !suspended, let lastFrame,
              ProcessInfo.processInfo.systemUptime - lastFrame > 1.5 else { return }
        cover.setVisible(attention.unavailable())
        updateStatus("Covered · camera unavailable; pause to retry")
    }

    @objc private func changeTolerance(_ sender: NSSlider) {
        attention.tolerance = sender.doubleValue
        defaults.set(attention.tolerance, forKey: "tolerance")
    }

    private func updateStatus(_ text: String) {
        guard stateItem.title != text || statusItem.button?.image == nil else { return }
        stateItem.title = text
        toggleItem.title = enabled ? "Pause protection" : "Enable protection"
        let symbol = enabled ? (cover.isVisible ? "eye.slash.fill" : "eye.fill") : "eye.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Screen Privacy: \(text)")
        statusItem.button?.toolTip = "Screen Privacy: \(text)"
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping @MainActor @Sendable (AppDelegate) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, observer))
    }

    private func lifecycleChanged() {
        if enabled { resume() }
    }

    private func observeLifecycle() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, center: workspace) { $0.sleeping = true; $0.lifecycleChanged() }
        observe(NSWorkspace.didWakeNotification, center: workspace) { $0.sleeping = false; $0.lifecycleChanged() }
        observe(NSWorkspace.screensDidSleepNotification, center: workspace) { $0.screensSleeping = true; $0.lifecycleChanged() }
        observe(NSWorkspace.screensDidWakeNotification, center: workspace) { $0.screensSleeping = false; $0.lifecycleChanged() }
        observe(NSWorkspace.sessionDidResignActiveNotification, center: workspace) { $0.sessionInactive = true; $0.lifecycleChanged() }
        observe(NSWorkspace.sessionDidBecomeActiveNotification, center: workspace) { $0.sessionInactive = false; $0.lifecycleChanged() }
        // Supplemental macOS notifications; workspace lifecycle remains the public-API fallback.
        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), center: distributed) { $0.screenLocked = true; $0.lifecycleChanged() }
        observe(Notification.Name("com.apple.screenIsUnlocked"), center: distributed) { $0.screenLocked = false; $0.lifecycleChanged() }
        observe(NSApplication.didChangeScreenParametersNotification, center: .default) { $0.cover.rebuild() }
        observe(AVCaptureDevice.wasDisconnectedNotification, center: .default) { $0.lifecycleChanged() }
        observe(AVCaptureDevice.wasConnectedNotification, center: .default) { $0.lifecycleChanged() }
        observe(AVCaptureSession.runtimeErrorNotification, center: .default) { app in
            guard app.enabled, !app.suspended else { return }
            app.cover.setVisible(app.attention.unavailable())
            app.updateStatus("Covered · camera error; pause to retry")
        }
    }

    private func showIntroduction() {
        let alert = NSAlert()
        alert.messageText = "Privacy when you look away"
        alert.informativeText = "Screen Privacy uses your camera to estimate head direction and covers your displays when you look away. Camera frames stay on this Mac and are never saved. The camera indicator stays on while protection is active.\n\nUse the eye icon in the menu bar to pause or adjust tolerance. This does not identify you or replace locking your Mac."
        alert.addButton(withTitle: "Enable protection")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { enableWithPermission() }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Screen Privacy"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        alert.informativeText = "Version \(version) · Open source under the MIT License\n\nThis app was made with ❤️ by Matti Vilola (iloapps.com)\n\nLocal head-direction detection. No recording, network requests, or accounts. Higher tolerance allows more movement and waits longer before covering.\n\nAny single person facing the camera can uncover the screen. Blur may leave content recognizable, and system UI can appear above the cover. Lock your Mac for security."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        stopCapture()
        cover.setVisible(false)
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
