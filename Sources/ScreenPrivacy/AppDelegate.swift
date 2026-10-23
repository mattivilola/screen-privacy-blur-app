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
    private var alarm = AlarmState()
    private var tamperEvidence = AlarmTamperEvidence()
    private let tamperToggleItem = NSMenuItem(title: "Alarm on closed lid or camera loss", action: #selector(toggleTamperAlarm), keyEquivalent: "")
    private let alarmAudio = AlarmAudio()
    private let hardwareMotion = HardwareMotionMonitor()
    private var motionSensorTest: MotionSensorTestController?
    private let sirenTestItem = NSMenuItem(title: "Test siren and flashing for 3 seconds", action: #selector(testAlarm), keyEquivalent: "")
    private let previewItem = NSMenuItem(title: "Preview cover for 5 seconds", action: #selector(previewCover), keyEquivalent: "")
    private let keepAwake = AlarmKeepAwake()
    private let alarmToggleItem = NSMenuItem(title: "Alarm mode", action: #selector(toggleAlarmMode), keyEquivalent: "")
    private let alarmInfoItem = NSMenuItem()
    private let alarmExplanation = MenuNoteView(text: "Off. Face the screen, then look away to arm.")
    private let sensorInfoItem = NSMenuItem()
    private let powerInfoItem = NSMenuItem()
    private var alarmTimer: Timer?
    private var alarmTestTimer: Timer?
    private var alarmTesting = false
    private var alarmFailure: String?
    private var alarmRequested = false
    private var alarmEnabled: Bool { alarm.phase != .off }
    private var sirenLevel: Double { min(max(defaults.object(forKey: "sirenLevel") as? Double ?? 1, 0.1), 1) }
    private let cover = PrivacyCover()
    private var attention = AttentionState()
    private var statusItem: NSStatusItem!
    private var appMenu: NSMenu!
    private var updaterController: SPUStandardUpdaterController?
    private let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem()
    private let statusHeader = StatusHeaderView()
    private let attentionMeter = AttentionMeterView(recoveryFraction: AttentionLimits.recoveryFraction)
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
    private var latestAnalysis: FrameAnalysis?
    private var watchdog: Timer?
    private var previewTimer: Timer?
    private var previewID: UUID?
    private var protectionCoverVisible = false
    private var protectionStatus = "Paused"
    private var protectionTone = DashboardTone.inactive
    private var displayedTone = DashboardTone.inactive
    private var cameraSubtitle = "Camera: Automatic"
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
        alarm.sensitivity = defaults.object(forKey: "alarmSensitivity") as? Double ?? 0.5
        alarm.countdown = defaults.object(forKey: "alarmCountdown") as? Double ?? 10
        alarmAudio.recoverPreviousVolume()
        keepAwake.onStatusChange = { [weak self] in self?.refreshAlarm() }
        keepAwake.onSafetyStop = { [weak self] reason in
            self?.disarmAlarm()
            self?.updateStatus("Alarm stopped · \(reason)", tone: .alert)
        }
        buildMenu()
        if let recoveryStatus = hardwareMotion.recoverPendingInterval() { sensorInfoItem.title = recoveryStatus }
        observeLifecycle()
        registerGlobalHotKey()
        // This launch-only switch supports bundle smoke tests without camera access.
        if CommandLine.arguments.contains("--smoke-test") {
            print("Screen Privacy launched; menu ready; camera not started")
            NSApp.terminate(nil)
            return
        }
        if CommandLine.arguments.contains("--motion-sensor-test") {
            showMotionSensorTest()
            return
        }
        if CommandLine.arguments.contains("--menu-test") {
            cover.captureAllowed = false
            DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
            return
        }
        // Native presentation checks keep camera capture and automatic updates off.
        if CommandLine.arguments.contains("--welcome-test") { showIntroduction(); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--about-test") { showAbout(); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--message-test") { editMessage(); NSApp.terminate(nil); return }
        if CommandLine.arguments.contains("--permission-test") { screenCapturePermission(); NSApp.terminate(nil); return }
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
        // Grouped by purpose: protection, live check, detection, cover, setup, then meta.
        stateItem.view = statusHeader
        menu.addItem(stateItem)
        toggleItem.target = self
        toggleItem.keyEquivalent = "p"
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Camera check"))
        let meterItem = NSMenuItem()
        meterItem.view = attentionMeter
        menu.addItem(meterItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Alarm"))
        alarmToggleItem.target = self
        alarmToggleItem.image = Self.symbol("bell.badge")
        menu.addItem(alarmToggleItem)
        alarmInfoItem.isEnabled = false
        alarmInfoItem.title = "Off · arms after you look away"
        alarmInfoItem.view = alarmExplanation
        menu.addItem(alarmInfoItem)
        let settingsItem = NSMenuItem(title: "Alarm settings", action: nil, keyEquivalent: "")
        let settings = NSMenu(title: "Alarm settings")
        settings.autoenablesItems = false
        settingsItem.submenu = settings
        sensorInfoItem.title = "Motion sensor checked when Alarm mode starts"
        sensorInfoItem.isEnabled = false; settings.addItem(sensorInfoItem)
        powerInfoItem.title = "Keep awake starts with Alarm mode"
        powerInfoItem.isEnabled = false; settings.addItem(powerInfoItem)
        let sensorTest = NSMenuItem(title: "Test motion sensor…", action: #selector(showMotionSensorTest), keyEquivalent: "")
        sensorTest.target = self
        sensorTest.image = Self.symbol("waveform.path")
        settings.addItem(sensorTest)
        settings.addItem(.separator())
        let sensitivity = NSMenuItem()
        sensitivity.view = SettingSliderView(title: "Sensitivity", leftLabel: "Less sensitive", rightLabel: "More sensitive",
            accessibilityLabel: "Alarm movement sensitivity", toolTip: "Higher sensitivity detects smaller sustained acceleration or tilt. A calibrated physical sensor is primary; camera motion is the fallback.",
            value: alarm.sensitivity, describe: { value in
                SettingReading(valueText: "\(Int(value * 100))%", tierName: value < 0.34 ? "Lower" : (value < 0.67 ? "Balanced" : "Higher"), tone: .balanced,
                               detail: "Find your balance with the silent test",
                               technicalDetail: String(format: "Sensor: %.3f g RMS for 0.35 seconds, or %.0f° tilt for 0.5 seconds.", PhysicalMotionPolicy.accelerationThreshold(sensitivity: value), PhysicalMotionPolicy.tiltThreshold(sensitivity: value)))
            }, onChange: { [weak self] value in
                self?.alarm.sensitivity = value; self?.defaults.set(value, forKey: "alarmSensitivity")
                self?.motionSensorTest?.setSensitivity(value)
            })
        settings.addItem(sensitivity)
        let volume = NSMenuItem()
        volume.view = SettingSliderView(title: "Siren volume", leftLabel: "Quiet", rightLabel: "Maximum",
            accessibilityLabel: "Siren loudness", toolTip: "Built-in speaker volume is temporarily set to 100%; this slider controls siren loudness. Previous speaker settings return on disarm.",
            value: sirenLevel, describe: { value in
                SettingReading(valueText: "\(Int(max(0.1, value) * 100))%", tierName: "", tone: .balanced,
                               detail: "Previous speaker settings return afterward")
            }, onChange: { [weak self] value in self?.defaults.set(max(0.1, value), forKey: "sirenLevel") })
        settings.addItem(volume)
        let countdown = NSMenuItem()
        countdown.view = SettingSliderView(title: "Time to leave", leftLabel: "3 seconds", rightLabel: "30 seconds",
            accessibilityLabel: "Alarm arming countdown", toolTip: "Time to leave before movement detection is armed.",
            value: (alarm.countdown - 3) / 27, describe: { value in
                SettingReading(valueText: "\(Int((3 + value * 27).rounded())) s", tierName: "", tone: .balanced,
                               detail: "Looking back cancels the countdown")
            }, onChange: { [weak self] value in
                let seconds = (3 + value * 27).rounded()
                self?.alarm.countdown = seconds; self?.defaults.set(seconds, forKey: "alarmCountdown")
            })
        settings.addItem(countdown)
        tamperToggleItem.target = self
        tamperToggleItem.state = tamperAlarmEnabled ? .on : .off
        tamperToggleItem.toolTip = "Once armed, a closed lid, missing camera frames, or a black/white camera image triggers the alarm after a short grace period. Camera faults can also trigger it."
        settings.addItem(tamperToggleItem)
        settings.addItem(.separator())
        let sirenNote = NSMenuItem()
        sirenNote.view = MenuNoteView(text: "The siren test temporarily uses maximum built-in speaker volume. Your previous settings return afterward.")
        settings.addItem(sirenNote)
        sirenTestItem.target = self; settings.addItem(sirenTestItem)
        let power = NSMenuItem(title: "Keep awake with the lid closed…", action: #selector(prepareLidClosed), keyEquivalent: "")
        power.target = self; settings.addItem(power)
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Privacy detection"))
        let toleranceItem = NSMenuItem()
        toleranceItem.view = SettingSliderView(
            title: "Head movement", leftLabel: "Stricter", rightLabel: "More forgiving",
            accessibilityLabel: "Head position and look-away tolerance",
            toolTip: "Higher tolerance allows more head movement and waits longer before covering.",
            value: attention.tolerance,
            describe: DashboardFormatting.toleranceReading,
            onChange: { [weak self] value in self?.setTolerance(value) })
        menu.addItem(toleranceItem)
        cameraMenuItem.submenu = cameraSubmenu
        cameraMenuItem.image = Self.symbol("camera")
        updateCameraMenu()
        menu.addItem(cameraMenuItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Screen cover"))
        let blurItem = NSMenuItem()
        blurItem.view = SettingSliderView(
            title: "Blur level", leftLabel: "Heavy blur", rightLabel: "Readable",
            accessibilityLabel: "Cover blur level",
            toolTip: "Drag left to hide more of the cover; right keeps text more readable.",
            value: blurStrength,
            describe: DashboardFormatting.blurReading,
            onChange: { [weak self] value in self?.setBlurStrength(value) })
        menu.addItem(blurItem)
        let message = NSMenuItem(title: "Screen message…", action: #selector(editMessage), keyEquivalent: "")
        message.target = self
        message.image = Self.symbol("text.bubble")
        menu.addItem(message)
        previewItem.target = self
        previewItem.image = Self.symbol("eye")
        menu.addItem(previewItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Setup"))
        let screenAccess = NSMenuItem(title: "Blurred cover permission…", action: #selector(screenCapturePermission), keyEquivalent: "")
        screenAccess.target = self
        screenAccess.image = Self.symbol("rectangle.dashed.badge.record")
        menu.addItem(screenAccess)
        launchAtLoginItem.target = self
        launchAtLoginItem.image = Self.symbol("person.crop.circle.badge.checkmark")
        updateLaunchAtLoginState()
        menu.addItem(launchAtLoginItem)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "About Screen Privacy…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        about.image = Self.symbol("info.circle")
        menu.addItem(about)
        checkUpdatesItem.isEnabled = false
        checkUpdatesItem.image = Self.symbol("arrow.triangle.2.circlepath")
        menu.addItem(checkUpdatesItem)
        let quit = NSMenuItem(title: "Quit Screen Privacy", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        quit.image = Self.symbol("power")
        menu.addItem(quit)
        statusItem.menu = menu
        updateStatus("Paused", tone: .inactive)
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkUpdatesItem.isEnabled = updaterController?.updater.canCheckForUpdates ?? false
        refreshAttentionMeter()
    }

    @objc private func toggle() {
        guard !permissionPending, motionSensorTest == nil else { return }
        disarmAlarm()
        endPreview()
        if enabled {
            enabled = false
            defaults.set(false, forKey: "enabled")
            stopCapture()
            setCoverVisible(false)
            updateStatus("Paused", tone: .inactive)
        } else {
            enableWithPermission()
        }
        refreshAttentionMeter()
        // Keep the complete menu attached while protection changes the status title.
        statusItem.menu = appMenu
    }

    @objc private func previewCover() {
        guard motionSensorTest == nil, !suspended else { return }
        explainScreenCaptureIfNeeded()
        previewTimer?.invalidate()
        let token = UUID()
        previewID = token
        cover.setVisible(true)
        updateStatus(protectionStatus, tone: protectionTone)
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
        cover.setVisible(protectionCoverVisible || alarm.isLatched || alarmTesting)
        updateStatus(protectionStatus, tone: protectionTone)
    }

    private func setCoverVisible(_ visible: Bool) {
        protectionCoverVisible = visible
        cover.setVisible(visible || previewID != nil || alarm.isLatched || alarmTesting)
    }

    @objc private func editMessage() {
        let editor = MessageEditor()
        guard let message = editor.run(currentMessage: cover.message) else { return }
        defaults.set(message, forKey: "coverMessage")
        cover.message = message
    }

    private func enableWithPermission() {
        guard motionSensorTest == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            explainScreenCaptureIfNeeded()
            enabled = true
            defaults.set(true, forKey: "enabled")
            resume()
            if alarmRequested { alarmRequested = false; beginAlarmMode() }
        case .notDetermined:
            permissionPending = true
            toggleItem.isEnabled = false
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.permissionPending = false
                    self.toggleItem.isEnabled = self.motionSensorTest == nil
                    if granted { self.enableWithPermission() }
                    else { self.alarmRequested = false; self.updateStatus("Camera permission required", tone: .alert) }
                }
            }
        default:
            alarmRequested = false
            updateStatus("Camera permission required", tone: .alert)
            let alert = NSAlert()
            alert.messageText = "Camera access is needed"
            alert.informativeText = "Enable Screen Privacy in System Settings → Privacy & Security → Camera, then enable protection again. Frames are processed locally and never saved."
            alert.addButton(withTitle: "Open Camera Settings")
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
            updateStatus("Protection suspended", tone: .inactive)
            refreshAttentionMeter()
            return
        }
        updateStatus("Covered · checking attention", tone: .caution)
        refreshAttentionMeter()
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
        alarm.interrupt()
        watchdog?.invalidate()
        watchdog = nil
        lastFrame = nil
        latestAnalysis = nil
        camera.stop()
    }

    private func receive(_ event: CameraEvent) {
        defer { refreshAttentionMeter() }
        switch event {
        case let .frame(analysis):
            guard ProcessInfo.processInfo.systemUptime - analysis.time < 1 else {
                setCoverVisible(attention.unavailable())
                updateStatus("Covered · waiting for fresh frames", tone: .alert)
                return
            }
            if lastFrame.map({ analysis.time - $0 > 1 }) == true { alarm.interrupt() }
            lastFrame = analysis.time
            latestAnalysis = analysis
            setCoverVisible(attention.update(faces: analysis.faces, at: analysis.time))
            if alarmEnabled && !alarmTesting {
                alarm.observe(watching: !protectionCoverVisible, cameraMotion: analysis.motionScore, at: analysis.time)
                if let score = analysis.motionScore { alarm.motion(score, source: "camera", at: analysis.time) }
                refreshAlarm()
            }
            if protectionCoverVisible {
                updateStatus(Self.coveredStatus(for: analysis), tone: .caution)
            } else {
                updateStatus("Protection active", tone: .good)
            }
        case let .motion(score, time):
            lastFrame = time
            guard alarmEnabled, !alarmTesting, ProcessInfo.processInfo.systemUptime - time < 1 else { return }
            alarm.motion(score, source: "camera", at: time)
            refreshAlarm()
        case let .unavailable(reason):
            latestAnalysis = nil
            if !alarm.isLatched { alarm.interrupt() }
            setCoverVisible(attention.unavailable())
            updateStatus("Covered · \(reason)", tone: .alert)
        }
    }

    /// Names harsh lighting as the reason when no face was found.
    private static func coveredStatus(for analysis: FrameAnalysis) -> String {
        guard analysis.faces.isEmpty else { return "Screen covered · look toward the camera" }
        switch analysis.lighting {
        case .bright: return "Screen covered · no face in bright light"
        case .backlit: return "Screen covered · no face against bright background"
        case .dark: return "Screen covered · no face in low light"
        case .normal: return "Screen covered · no face detected"
        }
    }

    private func refreshAttentionMeter() {
        attentionMeter.update(DashboardFormatting.attentionReading(
            protectionEnabled: enabled, suspended: suspended, analysis: latestAnalysis,
            now: ProcessInfo.processInfo.systemUptime, tolerance: attention.tolerance))
    }

    private func checkFreshness() {
        refreshAttentionMeter()
        guard enabled, !suspended, let lastFrame,
              ProcessInfo.processInfo.systemUptime - lastFrame > 1.5 else { return }
        setCoverVisible(attention.unavailable())
        updateStatus("Covered · camera unavailable; pause to retry", tone: .alert)
    }

    private func setTolerance(_ value: Double) {
        attention.tolerance = value
        defaults.set(attention.tolerance, forKey: "tolerance")
        // Immediate feedback: re-read the stored face against the new limits.
        refreshAttentionMeter()
    }

    /// Strength 0–1 maps to a Gaussian radius via `SnapshotDisplay.blurRadiusPoints(forStrength:)`;
    /// 0.5 is the historical default.
    private static let defaultBlurStrength = 0.5

    private var blurStrength: Double {
        let value = defaults.double(forKey: "blurStrength")
        return defaults.object(forKey: "blurStrength") == nil
            ? Self.defaultBlurStrength
            : min(max(value.isFinite ? value : Self.defaultBlurStrength, 0), 1)
    }

    private func setBlurStrength(_ value: Double) {
        cover.blurStrength = value
        defaults.set(cover.blurStrength, forKey: "blurStrength")
    }

    private func updateCameraMenu() {
        cameraSubmenu.removeAllItems()
        let devices = CameraMonitor.availableDevices()
        let selectedID = defaults.string(forKey: "selectedCameraID")
        let selectedName = devices.first(where: { $0.id == selectedID })?.localizedName
        cameraSubtitle = "Camera: \(selectedName ?? "Automatic")"
        renderStatusHeader()

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
            let alert = NSAlert()
            alert.messageText = "Couldn’t change startup settings"
            alert.informativeText = "Try again, or allow Screen Privacy in System Settings → General → Login Items."
            alert.addButton(withTitle: "Done")
            alert.window.level = .statusBar
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
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

    private func updateStatus(_ text: String, tone: DashboardTone) {
        protectionStatus = text
        protectionTone = tone
        let text = alarmEnabled || alarmTesting ? alarmStatus : (previewID == nil ? text : "Preview · 5 seconds")
        let alarmTone: DashboardTone = alarmTesting || alarm.phase == .alarming || alarmFailure != nil ? .alert : .balanced
        let tone: DashboardTone = alarmEnabled || alarmTesting ? alarmTone : (previewID == nil ? tone : .balanced)
        guard stateItem.title != text || displayedTone != tone || statusItem.button?.image == nil else { return }
        stateItem.title = text
        displayedTone = tone
        renderStatusHeader()
        toggleItem.title = enabled ? "Pause protection" : "Enable protection"
        toggleItem.image = Self.symbol(enabled ? "pause.circle" : "play.circle")
        let symbol = enabled ? (cover.isVisible ? "eye.slash.fill" : "eye.fill") : "eye.slash"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Screen Privacy: \(text)")
        statusItem.button?.toolTip = "Screen Privacy: \(text)"
    }

    private func renderStatusHeader() {
        let symbol = alarmEnabled || alarmTesting ? "bell" : (enabled ? (cover.isVisible ? "eye.slash" : "eye") : "pause.circle")
        statusHeader.update(title: stateItem.title, subtitle: cameraSubtitle, tone: displayedTone, symbolName: symbol)
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
        if sleeping { disarmAlarm() }
        alarm.interrupt()
        if suspended {
            endPreview()
            if alarmTesting { disarmAlarm() }
        }
        if enabled { resume() } else { refreshAttentionMeter() }
        refreshAlarm()
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
        observe(NSApplication.didBecomeActiveNotification, center: .default) { $0.cover.refreshSnapshotIfNeeded(); $0.keepAwake.refreshApproval() }
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
            app.updateStatus("Covered · camera error; pause to retry", tone: .alert)
            app.refreshAttentionMeter()
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
        alert.icon = appIcon
        alert.informativeText = "Cover your displays when you look away. Face the camera to uncover them again."
        alert.accessoryView = ExplanationView(items: [
            ExplanationItem(symbol: "camera", title: "Camera stays on this Mac", message: "The camera runs while protection is on. Frames are processed here and never saved."),
            ExplanationItem(symbol: "rectangle.on.rectangle", title: "A frozen, blurred cover", message: "Allow Screen Recording for a blurred snapshot. Without it, the cover is opaque."),
            ExplanationItem(symbol: "hand.raised", title: "You stay in control", message: "Pause from the menu bar or press ⌥⌘P. Anyone facing the camera can uncover the screen; this is not a lock.")
        ])
        alert.addButton(withTitle: "Enable Protection")
        alert.addButton(withTitle: "Not Now")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { enableWithPermission() }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Screen Privacy"
        alert.icon = appIcon
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        alert.informativeText = "Version \(version) · Open source under the MIT License\n\nMade with ❤️ by Matti Vilola · iloapps.com"
        alert.accessoryView = ExplanationView(items: [
            ExplanationItem(symbol: "lock.shield", title: "Private by design", message: "Camera and screen images stay on this Mac. No account or analytics."),
            ExplanationItem(symbol: "eye.slash", title: "A cover, not a lock", message: "Anyone facing the camera can uncover it. A frozen image may remain recognizable. Lock macOS for access control."),
            ExplanationItem(symbol: "arrow.triangle.2.circlepath", title: "Signed app updates", message: "Sparkle checks GitHub for new versions.")
        ])
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open Help & Source")
        alert.window.level = .statusBar
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/mattivilola/screen-privacy-blur-app#readme") { NSWorkspace.shared.open(url) }
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
            alert.messageText = "Your blurred cover is ready"
            alert.informativeText = "The cover can show a blurred, frozen snapshot. It stays on this Mac and is discarded when you return."
            alert.addButton(withTitle: "Done")
            alert.window.level = .statusBar
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        defaults.set(true, forKey: "screenCaptureExplained")
        let alert = NSAlert()
        alert.messageText = "Allow a blurred screen cover"
        alert.informativeText = "Use a frozen snapshot instead of an opaque cover."
        alert.accessoryView = ExplanationView(items: [
            ExplanationItem(symbol: "rectangle.dashed.badge.record", title: "macOS calls this Screen Recording", message: "Screen Privacy takes one still image per display. The blurred cover stays frozen, hiding later messages and window changes."),
            ExplanationItem(symbol: "lock.shield", title: "Nothing is saved or uploaded", message: "Snapshots stay in memory and are discarded when you return. macOS may ask you to reopen the app after granting access.")
        ])
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
        motionSensorTest?.invalidate()
        motionSensorTest = nil
        disarmAlarm()
        keepAwake.terminate()
        endPreview()
        stopCapture()
        setCoverVisible(false)
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}


// MARK: - Alarm mode
extension AppDelegate {
    @objc private func toggleAlarmMode() {
        guard motionSensorTest == nil else { return }
        if alarmEnabled || alarmTesting || alarmRequested { disarmAlarm(); return }
        if enabled { beginAlarmMode() }
        else { alarmRequested = true; enableWithPermission() }
    }

    private func beginAlarmMode() {
        guard enabled, !suspended else { alarmRequested = false; return }
        endPreview()
        alarmFailure = nil
        alarm.enable()
        tamperEvidence.reset()
        hardwareMotion.startSamples { [weak self] sample in
            guard let self, self.alarmEnabled, !self.alarmTesting, !self.sleeping else { return }
            self.alarm.receiveSensor(sample)
            self.refreshAlarm()
        }
        keepAwake.start()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAlarm() }
        }
        alarmTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshAlarm()
    }

    private func disarmAlarm() {
        alarmRequested = false
        alarm.disable()
        tamperEvidence.reset()
        alarmTesting = false
        alarmTestTimer?.invalidate(); alarmTestTimer = nil
        alarmTimer?.invalidate(); alarmTimer = nil
        hardwareMotion.stop()
        alarmAudio.restore()
        keepAwake.stop()
        alarmFailure = nil
        cover.alarmSounding = false
        cover.alarmStatus = nil
        cover.setVisible(protectionCoverVisible || previewID != nil)
        alarmToggleItem.state = .off
        alarmInfoItem.title = "Off · arms after you look away"
        alarmExplanation.update(text: "Off. Face the screen, then look away to arm.")
        if alarmAudio.restorationPending {
            updateStatus("Speaker restore pending · retry disarm", tone: .alert)
        } else { updateStatus(protectionStatus, tone: protectionTone) }
    }

    private var alarmStatus: String {
        if let alarmFailure { return "Alarm · \(alarmFailure)" }
        if alarmTesting { return "ALARM! · 3-second test" }
        switch alarm.phase {
        case .off: return "Alarm off"
        case .waiting: return suspended ? "Alarm waiting · monitoring suspended" : "Alarm mode · face screen, then look away"
        case let .countdown(until):
            let remaining = Int(ceil(until - ProcessInfo.processInfo.systemUptime))
            return remaining > 0 ? "Alarm arms in \(remaining) s" : "Alarm settling · stand clear"
        case .armed:
            let fresh = !suspended && lastFrame.map { ProcessInfo.processInfo.systemUptime - $0 <= 1.5 } == true
            if alarm.usesPhysicalPrimary(at: ProcessInfo.processInfo.systemUptime), !sleeping { return "Alarm armed · sensing laptop movement" }
            if fresh { return "Alarm armed · watching camera movement" }
            return "Alarm armed · monitoring unavailable"
        case .alarming: return "ALARM! · disarm from menu or ⌥⌘P"
        }
    }

    private func refreshAlarm() {
        guard alarmEnabled || alarmTesting else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let freshCamera = !suspended && lastFrame.map { now - $0 <= 1.5 } == true
        if tamperAlarmEnabled, !alarmTesting, !sessionInactive,
           tamperEvidence.update(armed: alarm.phase == .armed, lidClosed: LidState.isClosed,
                                 cameraAvailable: freshCamera, obscured: latestAnalysis?.isObscured == true, at: now) {
            alarm.trigger()
        }
        let sounding = alarm.phase == .alarming || alarmTesting
        if sounding, alarmFailure == nil {
            do { try alarmAudio.start(volume: sirenLevel) }
            catch { alarmFailure = error.localizedDescription }
        }
        cover.alarmStatus = alarmStatus
        let canPresent = !sleeping && !sessionInactive && !screenLocked && !screensSleeping
        cover.alarmSounding = sounding && canPresent
        if alarm.isLatched || alarmTesting { cover.setVisible(canPresent) }
        alarmToggleItem.state = alarmEnabled ? .on : .off
        alarmInfoItem.title = alarmStatus
        alarmExplanation.update(text: alarmStatus)
        alarmInfoItem.toolTip = "\(hardwareMotion.statusText) · \(keepAwake.statusText)"
        sensorInfoItem.title = hardwareMotion.isMonitoring ? (alarm.usesPhysicalPrimary(at: now) ? "Motion sensor ready" : "Motion sensor · keep the Mac still") : "Motion sensor unavailable"
        sensorInfoItem.toolTip = hardwareMotion.statusText
        powerInfoItem.title = keepAwake.statusText
        powerInfoItem.toolTip = keepAwake.statusText
        updateStatus(protectionStatus, tone: protectionTone)
    }

    @objc private func testAlarm() {
        guard motionSensorTest == nil, !alarmTesting, !suspended, alarm.phase != .alarming else { return }
        alarm.interrupt()
        tamperEvidence.reset()
        alarmTesting = true
        alarmFailure = nil
        refreshAlarm()
        let timer = Timer(timeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.alarmTesting = false
                self.alarm.interrupt()
                self.tamperEvidence.reset()
                self.alarmAudio.restore()
                self.alarmFailure = nil
                self.cover.alarmSounding = false
                self.cover.alarmStatus = self.alarmEnabled ? self.alarmStatus : nil
                self.cover.setVisible(self.protectionCoverVisible || self.previewID != nil || self.alarm.isLatched)
                self.updateStatus(self.protectionStatus, tone: self.protectionTone)
            }
        }
        alarmTestTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private var tamperAlarmEnabled: Bool { defaults.object(forKey: "alarmOnCameraLoss") as? Bool ?? true }
    @objc private func toggleTamperAlarm() {
        defaults.set(!tamperAlarmEnabled, forKey: "alarmOnCameraLoss")
        tamperToggleItem.state = tamperAlarmEnabled ? .on : .off
        tamperEvidence.reset()
    }

    @objc private func prepareLidClosed() { keepAwake.prepareLidClosed() }
}


// MARK: - Silent physical sensor diagnostic
extension AppDelegate {
    @objc private func showMotionSensorTest() {
        if let motionSensorTest { motionSensorTest.present(); return }
        let restoreProtection = enabled
        let test = MotionSensorTestController(sensitivity: alarm.sensitivity, protectionWasEnabled: restoreProtection)
        motionSensorTest = test
        disarmAlarm()
        endPreview()
        enabled = false
        stopCapture()
        setCoverVisible(false)
        for item in [toggleItem, alarmToggleItem, previewItem, sirenTestItem] { item.isEnabled = false }
        test.onClose = { [weak self] in
            guard let self else { return }
            self.motionSensorTest = nil
            self.toggleItem.isEnabled = !self.permissionPending
            for item in [self.alarmToggleItem, self.previewItem, self.sirenTestItem] { item.isEnabled = true }
            self.enabled = restoreProtection
            if restoreProtection { self.resume() }
            else { self.updateStatus("Paused", tone: .inactive) }
            self.refreshAttentionMeter()
        }
        updateStatus("Sensor test · protection paused", tone: .balanced)
        refreshAttentionMeter()
        test.present()
    }
}
