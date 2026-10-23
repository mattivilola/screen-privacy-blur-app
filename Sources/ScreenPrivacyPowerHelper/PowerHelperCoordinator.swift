import Foundation
import IOKit.ps
import PowerHelperKit
import os

/// Owns the one lid-closed session, the deadline timer and the battery and heat guards.
/// Everything runs on the main actor; XPC callbacks hop here first.
@MainActor
final class PowerHelperCoordinator {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScreenPrivacyPowerHelper", category: "helper")
    private var engine: KeepAwakeSessionEngine!
    private var owner: NSXPCConnection?
    private var deadlineTimer: DispatchSourceTimer?
    private var ownershipTimer: DispatchSourceTimer?
    private var restoreRetryTimer: DispatchSourceTimer?
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var thermalObserver: NSObjectProtocol?

    init(journal: any KeepAwakeJournal) {
        engine = KeepAwakeSessionEngine(
            sleepSetting: PmsetSleepDisabledSetting(),
            journal: journal,
            notifyClient: { [unowned self] reason in
                // Only runs when the helper ended the session itself.
                let client = owner?.remoteObjectProxy as? any ScreenPrivacyPowerHelperClientProtocol
                client?.lidClosedSessionEnded(reason: reason)
            },
            log: { [logger] message in logger.error("\(message, privacy: .public)") }
        )
    }

    func start() {
        engine.recoverAtLaunch()
        updateRestoreRetryTimer()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateGuards() }
        }
    }

    /// Puts the setting back before the process exits, so a shutdown or an update never leaves the Mac awake.
    func prepareForTermination() {
        engine.end(reason: nil)
        engine.retryPendingRestore()
        sessionDidStop()
    }

    func begin(for connection: NSXPCConnection, endsAt: Date?) -> (success: Bool, message: String?) {
        if engine.isActive {
            guard owner === connection else {
                return (false, "Closed-lid keep awake is already owned by another Screen Privacy session.")
            }
            engine.verifyOwnership()
            guard engine.isActive else {
                sessionDidStop()
                return (false, KeepAwakeSessionError.sleepSettingChanged.localizedDescription)
            }
        } else if owner != nil, owner !== connection {
            return (false, "Closed-lid keep awake is already owned by another Screen Privacy session.")
        }

        let current = currentPowerState()
        guard current.isAvailable else {
            return (false, "Not available right now: power status could not be verified.")
        }
        if let reason = KeepAwakeSessionEngine.endReason(
            batteryPercent: current.batteryPercent,
            isOnAC: current.isOnAC,
            thermalState: ProcessInfo.processInfo.thermalState,
            powerStateAvailable: current.isAvailable
        ) {
            return (false, "Not available right now: \(reason).")
        }

        do {
            try engine.begin(endsAt: endsAt)
        } catch {
            logger.error("Could not begin a session: \(error.localizedDescription, privacy: .public)")
            updateRestoreRetryTimer()
            return (false, error.localizedDescription)
        }
        owner = connection
        scheduleDeadline()
        startPowerSourceGuard()
        startOwnershipGuard()
        return (true, nil)
    }

    func end(for connection: NSXPCConnection) {
        guard owner === connection else {
            return
        }
        engine.end(reason: nil)
        sessionDidStop()
    }

    func connectionEnded(_ connection: NSXPCConnection) {
        guard owner === connection else {
            return
        }
        engine.clientDisconnected()
        sessionDidStop()
    }

    // MARK: Guards

    private func evaluateGuards() {
        guard engine.isActive else {
            return
        }
        let current = currentPowerState()
        engine.evaluate(
            batteryPercent: current.batteryPercent,
            isOnAC: current.isOnAC,
            thermalState: ProcessInfo.processInfo.thermalState,
            powerStateAvailable: current.isAvailable
        )
        if engine.isActive == false {
            sessionDidStop()
        }
    }

    private func expireIfNeeded() {
        engine.expireIfNeeded()
        if engine.isActive {
            // The wall clock moved; arm the timer again for the new distance.
            scheduleDeadline()
        } else {
            sessionDidStop()
        }
    }

    private func verifyOwnership() {
        guard engine.isActive else { return }
        engine.verifyOwnership()
        if engine.isActive == false {
            sessionDidStop()
        }
    }

    private func sessionDidStop() {
        owner = nil
        deadlineTimer?.cancel()
        deadlineTimer = nil
        ownershipTimer?.cancel()
        ownershipTimer = nil
        stopPowerSourceGuard()
        updateRestoreRetryTimer()
    }

    /// Recovery remains active while idle whenever the journal says the helper may still own the setting.
    private func updateRestoreRetryTimer() {
        guard engine.hasPendingRestore else {
            restoreRetryTimer?.cancel()
            restoreRetryTimer = nil
            return
        }
        guard restoreRetryTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine.retryPendingRestore()
                if !self.engine.hasPendingRestore {
                    self.restoreRetryTimer?.cancel()
                    self.restoreRetryTimer = nil
                }
            }
        }
        timer.resume()
        restoreRetryTimer = timer
    }

    private func scheduleDeadline() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let endsAt = engine.endsAt else {
            return
        }

        // Wall-clock time, so the deadline keeps counting while the Mac sleeps.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let seconds = max(endsAt.timeIntervalSinceNow, 0)
        timer.schedule(wallDeadline: .now() + seconds, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.expireIfNeeded() }
        }
        timer.resume()
        deadlineTimer = timer
    }

    /// The sleep flag is global, so periodically confirm that it still belongs to this helper.
    private func startOwnershipGuard() {
        ownershipTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.verifyOwnership() }
        }
        timer.resume()
        ownershipTimer = timer
    }

    // MARK: Power state (event driven, no polling)

    private func startPowerSourceGuard() {
        guard powerSourceRunLoopSource == nil else {
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else {
                return
            }
            let coordinator = Unmanaged<PowerHelperCoordinator>.fromOpaque(context)
            MainActor.assumeIsolated {
                coordinator.takeUnretainedValue().evaluateGuards()
            }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else {
            logger.error("Could not watch the power source")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSourceRunLoopSource = source
    }

    private func stopPowerSourceGuard() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    private func currentPowerState() -> (batteryPercent: Int?, isOnAC: Bool, isAvailable: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let providing = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else {
            return (nil, false, false)
        }

        let isOnAC = providing != kIOPSBatteryPowerValue
        var batteryPercent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else {
                continue
            }
            batteryPercent = capacity * 100 / maximum
        }
        // A desktop Mac has no internal battery, so nil is expected on AC. On battery power,
        // missing capacity means the guard cannot prove that the safety threshold is respected.
        return (batteryPercent, isOnAC, isOnAC || batteryPercent != nil)
    }
}
