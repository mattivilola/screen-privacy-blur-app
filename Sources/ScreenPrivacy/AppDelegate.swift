import AppKit
import AVFoundation
import AttentionCore
import Carbon.HIToolbox
import OverlayUI
import ServiceManagement
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let camera = CameraMonitor()
    private let cover = PrivacyCover()
    private var attention = AttentionState()
    private var statusItem: NSStatusItem!
    private var appMenu: NSMenu!
    private var updaterController: SPUStandardUpdaterController?
    private let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Paused", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Enable protection", action: #selector(toggle), keyEquivalent: "")
    private let cameraMenuItem = NSMenuItem(title: "Camera", action: nil, keyEquivalent: "")
    private let cameraSubmenu = NSMenu(title: "Camera")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private var hotKeyRef: EventHotKeyRef?
    private var enabled = false
    private var permissionPending = false
    private var sleeping = false
    private var sessionInactive = false
    private var screenLocked = false
    private var screensSleeping = false
    private var generation = UUID()
    private var lastFrame: TimeInterval?
    private var watchdog: Timer?
    private var previewTimer: Timer?
    private var previewID: UUID?
    private var protectionCoverVisible = false
    private var protectionStatus = "Paused"
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var suspended: Bool { sleeping || sessionInactive || screenLocked || screensSleeping }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = appIcon {
            NSApp.applicationIconImage = icon
        }
        camera.preferredDeviceID = defaults.string(forKey: "selectedCameraID")
        attention.tolerance = defaults.object(forKey: "tolerance") as? Double ?? 0.5
        cover.message = defaults.string(forKey: "coverMessage") ?? ""
        cover.blurStrength = blurStrength
        buildMenu()
        observeLifecycle()
        registerGlobalHotKey()
        // This launch-only switch supports bundle smoke tests without camera access.
        if CommandLine.arguments.contains("--smoke-test") {
            print("Screen Privacy launched; menu ready; camera not started")
            NSApp.terminate(nil)
            return
        }
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        checkUpdatesItem.target = updaterController
        checkUpdatesItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
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
        appMenu = menu
        menu.autoenablesItems = false
        menu.delegate = self
        // Grouped by purpose: protection, tuning, verification, setup, then meta.
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        toggleItem.target = self
        toggleItem.keyEquivalent = "p"
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        menu.addItem(controlItem(title: "Tolerance", value: attention.tolerance,
                                 leftLabel: "Stricter", rightLabel: "More forgiving",
                                 action: #selector(changeTolerance(_:)),
                                 accessibility: "Head position and look-away tolerance",
                                 tooltip: "Higher tolerance allows more head movement and waits longer before covering."))
        menu.addItem(controlItem(title: "Blur level", value: blurStrength,
                                 leftLabel: "Heavy blur", rightLabel: "Readable",
                                 action: #selector(changeBlurStrength(_:)),
                                 accessibility: "Cover blur level",
                                 tooltip: "Drag left to hide more of the cover; right keeps text more readable."))
        let message = NSMenuItem(title: "Custom message…", action: #selector(editMessage), keyEquivalent: "")
        message.target = self
        menu.addItem(message)
        menu.addItem(.separator())

        cameraMenuItem.submenu = cameraSubmenu
        updateCameraMenu()
        menu.addItem(cameraMenuItem)

        launchAtLoginItem.target = self
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let preview = NSMenuItem(title: "Preview for 5 seconds", action: #selector(previewCover), keyEquivalent: "")
        preview.target = self
        menu.addItem(preview)
        menu.addItem(.separator())

        let screenAccess = NSMenuItem(title: "Screen Capture Permission…", action: #selector(screenCapturePermission), keyEquivalent: "")
        screenAccess.target = self
        menu.addItem(screenAccess)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Screen Privacy…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        checkUpdatesItem.isEnabled = false
        menu.addItem(checkUpdatesItem)
        let quit = NSMenuItem(title: "Quit Screen Privacy", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatus("Paused")
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkUpdatesItem.isEnabled = updaterController?.updater.canCheckForUpdates ?? false
    }

    @objc private func toggle() {
        guard !permissionPending else { return }
        endPreview()
        if enabled {
            enabled = false
            defaults.set(false, forKey: "enabled")
            stopCapture()
            setCoverVisible(false)
            updateStatus("Paused")
        } else {
            enableWithPermission()
        }
        // Keep the complete menu attached while protection changes the status title.
        statusItem.menu = appMenu
    }

    @objc private func previewCover() {
        guard !suspended else { return }
        explainScreenCaptureIfNeeded()
        previewTimer?.invalidate()
        let token = UUID()
        previewID = token
        cover.setVisible(true)
        updateStatus(protectionStatus)
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewID == token else { return }
                self.endPreview()
            }
        }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func endPreview() {
        guard previewID != nil else { return }
        previewTimer?.invalidate()
        previewTimer = nil
        previewID = nil
        cover.setVisible(protectionCoverVisible)
        updateStatus(protectionStatus)
    }

    private func setCoverVisible(_ visible: Bool) {
        protectionCoverVisible = visible
        cover.setVisible(visible || previewID != nil)
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
            explainScreenCaptureIfNeeded()
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
        setCoverVisible(true)
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
                setCoverVisible(attention.unavailable())
                updateStatus("Covered · waiting for fresh frames")
                return
            }
            lastFrame = time
            setCoverVisible(attention.update(faces: faces, at: time))
            updateStatus(protectionCoverVisible ? "Covered · look toward the camera" : "Protection active")
        case let .unavailable(reason):
            setCoverVisible(attention.unavailable())
            updateStatus("Covered · \(reason)")
        }
    }

    private func checkFreshness() {
        guard enabled, !suspended, let lastFrame,
              ProcessInfo.processInfo.systemUptime - lastFrame > 1.5 else { return }
        setCoverVisible(attention.unavailable())
        updateStatus("Covered · camera unavailable; pause to retry")
    }

    @objc private func changeTolerance(_ sender: NSSlider) {
        attention.tolerance = sender.doubleValue
        defaults.set(attention.tolerance, forKey: "tolerance")
    }

    /// Strength 0–1 maps to a Gaussian radius of 18→6 screen points; 0.5 is the historical 12.
    private static let defaultBlurStrength = 0.5

    private var blurStrength: Double {
        let value = defaults.double(forKey: "blurStrength")
        return defaults.object(forKey: "blurStrength") == nil
            ? Self.defaultBlurStrength
            : min(max(value.isFinite ? value : Self.defaultBlurStrength, 0), 1)
    }

    /// Shared layout for the embedded slider controls with pixel-perfect left and right labels.
    private func controlItem(title: String, value: Double, leftLabel: String, rightLabel: String,
                             action: Selector, accessibility: String, tooltip: String) -> NSMenuItem {
        let control = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 86))
        let label = NSTextField(labelWithString: title)
        label.frame = NSRect(x: 18, y: 60, width: 210, height: 18)
        control.addSubview(label)
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1,
                              target: self, action: action)
        slider.frame = NSRect(x: 16, y: 31, width: 218, height: 24)
        slider.isContinuous = true
        slider.setAccessibilityLabel(accessibility)
        slider.toolTip = tooltip
        control.addSubview(slider)
        let leftField = NSTextField(labelWithString: leftLabel)
        leftField.font = .systemFont(ofSize: 11)
        leftField.textColor = .secondaryLabelColor
        leftField.frame = NSRect(x: 18, y: 10, width: 105, height: 16)
        control.addSubview(leftField)
        let rightField = NSTextField(labelWithString: rightLabel)
        rightField.font = .systemFont(ofSize: 11)
        rightField.textColor = .secondaryLabelColor
        rightField.alignment = .right
        rightField.frame = NSRect(x: 125, y: 10, width: 109, height: 16)
        control.addSubview(rightField)
        let item = NSMenuItem()
        item.view = control
        return item
    }

    @objc private func changeBlurStrength(_ sender: NSSlider) {
        cover.blurStrength = sender.doubleValue
        defaults.set(cover.blurStrength, forKey: "blurStrength")
    }

    private func updateCameraMenu() {
        cameraSubmenu.removeAllItems()
        let devices = CameraMonitor.availableDevices()
        let selectedID = defaults.string(forKey: "selectedCameraID")

        let autoItem = NSMenuItem(title: "Automatic", action: #selector(selectCamera(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = nil
        autoItem.state = selectedID == nil ? .on : .off
        cameraSubmenu.addItem(autoItem)
        cameraSubmenu.addItem(.separator())

        if devices.isEmpty {
            let noneItem = NSMenuItem(title: "No Cameras Found", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            cameraSubmenu.addItem(noneItem)
        } else {
            for device in devices {
                let title = device.isSuspended ? "\(device.localizedName) (Closed/Suspended)" : device.localizedName
                let item = NSMenuItem(title: title, action: #selector(selectCamera(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.id
                item.state = selectedID == device.id ? .on : .off
                item.isEnabled = !device.isSuspended
                cameraSubmenu.addItem(item)
            }
        }
    }

    @objc private func selectCamera(_ sender: NSMenuItem) {
        let deviceID = sender.representedObject as? String
        defaults.set(deviceID, forKey: "selectedCameraID")
        camera.preferredDeviceID = deviceID
        updateCameraMenu()
        if enabled && !suspended {
            resume()
        }
    }

    private func updateLaunchAtLoginState() {
        let isEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginItem.state = isEnabled ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            print("Screen Privacy: Launch at login failed: \(error)")
        }
        updateLaunchAtLoginState()
    }

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in
                app.toggle()
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x53505256) /* 'SPRV' */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(cmdKey | optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            print("Screen Privacy: Could not register global hotkey (status: \(status))")
        }
    }

    private func updateStatus(_ text: String) {
        protectionStatus = text
        let text = previewID == nil ? text : "Preview · 5 seconds"
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
        cover.captureAllowed = !suspended
        if suspended { endPreview() }
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
        observe(NSApplication.didBecomeActiveNotification, center: .default) { $0.cover.refreshSnapshotIfNeeded() }
        observe(AVCaptureDevice.wasDisconnectedNotification, center: .default) { app in
            app.updateCameraMenu()
            app.lifecycleChanged()
        }
        observe(AVCaptureDevice.wasConnectedNotification, center: .default) { app in
            app.updateCameraMenu()
            app.lifecycleChanged()
        }
        observe(AVCaptureSession.runtimeErrorNotification, center: .default) { app in
            guard app.enabled, !app.suspended else { return }
            app.setCoverVisible(app.attention.unavailable())
            app.updateStatus("Covered · camera error; pause to retry")
        }
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
        return nil
    }

    private var brandLogo: NSImage? {
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        let localPath = "Assets/Logo.png"
        if FileManager.default.fileExists(atPath: localPath) {
            return NSImage(contentsOfFile: localPath)
        }
        return nil
    }

    private func showIntroduction() {
        let alert = NSAlert()
        alert.messageText = "Privacy when you look away"
        if let icon = appIcon {
            alert.icon = icon
        }
        if let logo = brandLogo {
            let logoView = NSImageView(frame: NSRect(x: 0, y: 0, width: 340, height: 191))
            logoView.image = logo
            logoView.imageScaling = .scaleProportionallyUpOrDown
            logoView.wantsLayer = true
            logoView.layer?.cornerRadius = 8
            logoView.layer?.masksToBounds = true
            alert.accessoryView = logoView
        }
        alert.informativeText = "Screen Privacy uses your camera to estimate head direction and covers your displays when you look away. Camera frames stay on this Mac and are never saved. The camera indicator stays on while protection is active.\n\nWith Screen Recording permission, the cover shows a locally blurred, frozen screenshot. New messages and window changes do not appear through it. Images stay in memory and are discarded when you return. Without permission, an opaque cover is used.\n\nUse the eye icon in the menu bar to pause or adjust tolerance and blur level. This does not identify you or replace locking your Mac."
        alert.addButton(withTitle: "Enable protection")
        alert.addButton(withTitle: "Later")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { enableWithPermission() }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Screen Privacy"
        if let icon = appIcon {
            alert.icon = icon
        }
        if let logo = brandLogo {
            let logoView = NSImageView(frame: NSRect(x: 0, y: 0, width: 340, height: 191))
            logoView.image = logo
            logoView.imageScaling = .scaleProportionallyUpOrDown
            logoView.wantsLayer = true
            logoView.layer?.cornerRadius = 8
            logoView.layer?.masksToBounds = true
            alert.accessoryView = logoView
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        alert.informativeText = "Version \(version) · Open source under the MIT License\n\nthis app made with ❤️ by Matti Vilola (iloapps.com)\n\nLocal head-direction detection. Higher tolerance allows more movement and waits longer before covering.\n\nWhy a frozen cover? A blurred screenshot hides later messages and window changes instead of showing a live view. It needs Screen Recording permission, but takes only a still image per display when covering. Images stay in memory and are discarded on return. Without permission, the cover is opaque.\n\nCamera and screen images are never uploaded. Sparkle contacts GitHub for signed app updates. No accounts or analytics.\n\nAny single person facing the camera can uncover the screen. The frozen image may remain recognizable, and system UI can appear above it. Lock your Mac for security."
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func explainScreenCaptureIfNeeded() {
        // The permission can be revoked or invalidated when a newly signed local
        // build is launched. Do not let the old explanation flag hide the reason
        // the cover is opaque; show the recovery flow whenever capture is absent.
        guard !CGPreflightScreenCaptureAccess() else { return }
        screenCapturePermission()
    }

    @objc private func screenCapturePermission() {
        if CGPreflightScreenCaptureAccess() {
            cover.refreshSnapshotIfNeeded()
            let alert = NSAlert()
            alert.messageText = "Screen capture is allowed"
            alert.informativeText = "The cover uses a blurred, frozen screenshot. Images are kept only in memory and discarded when the cover clears."
            alert.window.level = .statusBar
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        defaults.set(true, forKey: "screenCaptureExplained")
        let alert = NSAlert()
        alert.messageText = "Allow a frozen, blurred screen cover"
        alert.informativeText = "Screen Privacy takes one still image per display when covering, blurs it locally, and keeps it frozen so later messages and window changes stay hidden. Nothing is saved or sent anywhere.\n\nmacOS calls this Screen Recording permission. Without it, protection uses an opaque cover. After granting access, macOS may ask you to quit and reopen the app."
        alert.addButton(withTitle: "Allow Screen Capture")
        alert.addButton(withTitle: "Use Opaque Cover")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if CGRequestScreenCaptureAccess() {
            cover.refreshSnapshotIfNeeded()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        endPreview()
        stopCapture()
        setCoverVisible(false)
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
