import Foundation

/// What the app asks of the privileged helper. The helper does exactly one thing: it holds the global
/// `SleepDisabled` power setting on for the lifetime of one session, so a closed lid does not sleep the Mac.
@objc public protocol ScreenPrivacyPowerHelperProtocol {
    /// Starts a lid-closed session, or only updates the deadline when one is already active.
    /// `endsAt` is nil for a session that runs until the app ends it.
    func beginLidClosedSession(endsAt: Date?, reply: @escaping @Sendable (Bool, String?) -> Void)

    func endLidClosedSession(reply: @escaping @Sendable () -> Void)
}

/// What the app exports on the same connection, so the helper can tell it that it ended a session on its own.
@objc public protocol ScreenPrivacyPowerHelperClientProtocol {
    /// Called when the helper ends the session without being asked: deadline, low battery or critical heat.
    /// `reason` is a short, user-facing phrase such as "battery low".
    func lidClosedSessionEnded(reason: String)
}
