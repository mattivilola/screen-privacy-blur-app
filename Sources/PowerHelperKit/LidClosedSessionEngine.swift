import Foundation

/// The global macOS `SleepDisabled` setting (`pmset disablesleep`).
public protocol SleepDisabledSetting {
    func isSleepDisabled() throws -> Bool
    func setSleepDisabled(_ isDisabled: Bool) throws
}

/// What the helper writes to disk before it changes the setting, so it can put it back after a crash or reboot.
public struct KeepAwakeJournalRecord: Codable, Equatable, Sendable {
    public var priorSleepDisabled: Bool
    public var endsAt: Date?

    public init(priorSleepDisabled: Bool, endsAt: Date?) {
        self.priorSleepDisabled = priorSleepDisabled
        self.endsAt = endsAt
    }
}

public protocol KeepAwakeJournal {
    func load() throws -> KeepAwakeJournalRecord?
    func save(_ record: KeepAwakeJournalRecord) throws
    func delete() throws
}

public enum KeepAwakeSessionError: Error, Equatable, LocalizedError {
    case deadlineAlreadyPassed
    case sleepSettingAlreadyDisabled
    case sleepSettingChanged
    case restorePending
    case sleepSettingUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .deadlineAlreadyPassed:
            "The time for keeping the Mac awake has already passed."
        case .sleepSettingAlreadyDisabled:
            "Sleep is already disabled by another service or setting. Screen Privacy won't take it over."
        case .sleepSettingChanged:
            "Another service changed the Mac's sleep setting. Screen Privacy stopped keeping it awake."
        case .restorePending:
            "Screen Privacy is still restoring the previous sleep setting. Try again in a moment."
        case let .sleepSettingUnavailable(detail):
            "The Mac's sleep setting could not be changed: \(detail)"
        }
    }
}

/// Short, user-facing reasons the helper gives when it ends a session on its own.
public enum KeepAwakeSessionEndReason {
    public static let batteryLow = "battery low"
    public static let powerStatusUnavailable = "power status unavailable"
    public static let tooHot = "Mac too hot"
    public static let timeIsUp = "time is up"
    public static let sleepSettingChanged = "another service changed the sleep setting"
    public static let sleepSettingUnavailable = "sleep setting could not be verified"
}

/// The helper's whole decision logic, free of XPC, launchd and `pmset`, so it can be tested.
/// Not thread-safe: call it from one serial queue.
public final class KeepAwakeSessionEngine {
    public private(set) var endsAt: Date?

    private let sleepSetting: any SleepDisabledSetting
    private let journal: any KeepAwakeJournal
    private let now: () -> Date
    private let notifyClient: (String) -> Void
    private let log: (String) -> Void
    /// True only while this helper owns the transition from SleepDisabled=false to true.
    private var ownsSleepDisabled = false
    /// A journal-backed obligation to verify and restore the global setting, retried while the helper lives.
    private var cleanupPending = false

    public init(
        sleepSetting: any SleepDisabledSetting,
        journal: any KeepAwakeJournal,
        now: @escaping () -> Date = Date.init,
        notifyClient: @escaping (String) -> Void,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.sleepSetting = sleepSetting
        self.journal = journal
        self.now = now
        self.notifyClient = notifyClient
        self.log = log
    }

    public var isActive: Bool {
        ownsSleepDisabled
    }

    public var hasPendingRestore: Bool {
        cleanupPending
    }

    /// Starts a session only when SleepDisabled is off. This helper cannot compose with another owner of
    /// the same global `pmset` setting, so it refuses to take over a value already set to true.
    public func begin(endsAt: Date?) throws {
        if let endsAt, endsAt <= now() {
            throw KeepAwakeSessionError.deadlineAlreadyPassed
        }

        guard !cleanupPending else {
            throw KeepAwakeSessionError.restorePending
        }

        if ownsSleepDisabled {
            let isDisabled: Bool
            do {
                isDisabled = try sleepSetting.isSleepDisabled()
            } catch {
                end(reason: KeepAwakeSessionEndReason.sleepSettingUnavailable)
                throw KeepAwakeSessionError.sleepSettingUnavailable(error.localizedDescription)
            }
            guard isDisabled else {
                end(reason: KeepAwakeSessionEndReason.sleepSettingChanged)
                throw KeepAwakeSessionError.sleepSettingChanged
            }
            do {
                try journal.save(KeepAwakeJournalRecord(priorSleepDisabled: false, endsAt: endsAt))
            } catch {
                throw KeepAwakeSessionError.sleepSettingUnavailable(error.localizedDescription)
            }
            self.endsAt = endsAt
            return
        }

        do {
            guard try sleepSetting.isSleepDisabled() == false else {
                throw KeepAwakeSessionError.sleepSettingAlreadyDisabled
            }
            // The journal goes first: if we are killed right after changing the setting, the next launch can undo it.
            try journal.save(KeepAwakeJournalRecord(priorSleepDisabled: false, endsAt: endsAt))
            cleanupPending = true
            do {
                try sleepSetting.setSleepDisabled(true)
            } catch {
                // A command can report failure after changing the setting. Try to restore now, then
                // leave the journal-backed obligation active for the coordinator's retry timer.
                retryPendingRestore()
                throw error
            }
            ownsSleepDisabled = true
            cleanupPending = false
            self.endsAt = endsAt
        } catch let error as KeepAwakeSessionError {
            throw error
        } catch {
            throw KeepAwakeSessionError.sleepSettingUnavailable(error.localizedDescription)
        }
    }

    /// Ends the active session. A nil `reason` means the client asked for it and needs no notification.
    public func end(reason: String?) {
        guard ownsSleepDisabled || cleanupPending else {
            return
        }
        ownsSleepDisabled = false
        endsAt = nil
        cleanupPending = true
        retryPendingRestore()
        if let reason {
            notifyClient(reason)
        }
    }

    /// Undoes a session a crash or reboot left behind. Without a journal the setting is never touched, which
    /// respects a user's own `disablesleep 1`.
    public func recoverAtLaunch() {
        ownsSleepDisabled = false
        endsAt = nil
        cleanupPending = true
        retryPendingRestore()
    }

    /// The app quit or crashed, so nothing is left to keep awake for.
    public func clientDisconnected() {
        end(reason: nil)
    }

    /// Ends the session once its deadline has passed.
    public func expireIfNeeded() {
        guard let endsAt, now() >= endsAt else {
            return
        }
        end(reason: KeepAwakeSessionEndReason.timeIsUp)
    }

    /// Confirms this helper still owns the setting. If another service restores it, stop the session and
    /// discard the journal without writing `false` again.
    public func verifyOwnership() {
        guard ownsSleepDisabled else { return }
        do {
            guard try sleepSetting.isSleepDisabled() else {
                ownsSleepDisabled = false
                endsAt = nil
                cleanupPending = true
                retryPendingRestore()
                notifyClient(KeepAwakeSessionEndReason.sleepSettingChanged)
                return
            }
        } catch {
            ownsSleepDisabled = false
            endsAt = nil
            cleanupPending = true
            log("Could not verify ownership of the sleep setting: \(error.localizedDescription)")
            // Re-read once immediately in case this was transient. A recurring coordinator timer
            // continues while the journal remains pending.
            retryPendingRestore()
            notifyClient(KeepAwakeSessionEndReason.sleepSettingUnavailable)
        }
    }

    /// Why a session may not run (or must end) right now: a low battery that is not charging, or critical heat.
    /// Nil when it is fine to keep going. A missing battery level (a desktop Mac) never counts as low.
    public static func endReason(
        batteryPercent: Int?,
        isOnAC: Bool,
        thermalState: ProcessInfo.ThermalState,
        powerStateAvailable: Bool = true
    ) -> String? {
        if thermalState == .critical {
            return KeepAwakeSessionEndReason.tooHot
        }
        if !powerStateAvailable {
            return KeepAwakeSessionEndReason.powerStatusUnavailable
        }
        if isOnAC == false, let batteryPercent, batteryPercent <= PowerHelperIdentity.batteryFloorPercent {
            return KeepAwakeSessionEndReason.batteryLow
        }
        return nil
    }

    /// Ends the session when the battery is low (and not charging) or the Mac is critically hot.
    public func evaluate(
        batteryPercent: Int?,
        isOnAC: Bool,
        thermalState: ProcessInfo.ThermalState,
        powerStateAvailable: Bool = true
    ) {
        guard isActive,
              let reason = Self.endReason(
                batteryPercent: batteryPercent,
                isOnAC: isOnAC,
                thermalState: thermalState,
                powerStateAvailable: powerStateAvailable
              )
        else {
            return
        }
        end(reason: reason)
    }

    /// Retries the journal-backed restore while the helper remains alive. If the setting is already false,
    /// only the journal is removed; if reads or writes fail, the pending obligation remains visible.
    public func retryPendingRestore() {
        guard cleanupPending else { return }
        let record: KeepAwakeJournalRecord?
        do {
            record = try journal.load()
        } catch {
            log("Could not read the recovery journal: \(error.localizedDescription)")
            return
        }
        guard let record else {
            cleanupPending = false
            return
        }
        do {
            // A prior true value can only come from an older version; preserve it.
            if record.priorSleepDisabled == false, try sleepSetting.isSleepDisabled() {
                try sleepSetting.setSleepDisabled(false)
            }
            try journal.delete()
            cleanupPending = false
        } catch {
            log("Could not restore the sleep setting: \(error.localizedDescription)")
        }
    }
}
