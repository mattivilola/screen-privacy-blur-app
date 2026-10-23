import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while Alarm mode runs and, when macOS allows it, owns a
/// separate privileged session that permits the Mac to stay awake with its lid closed.
@MainActor
final class AlarmKeepAwake {
    var onStatusChange: (() -> Void)?
    var onSafetyStop: ((String) -> Void)?

    private(set) var statusText = "Closed-lid keep awake is off"

    private let client = PowerHelperClient()
    private var assertionID: IOPMAssertionID?
    private var assertionFailure: String?
    private var operationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var isStarted = false
    private var isStopping = false
    private var helperSessionStarted = false

    init() {
        client.eventHandler = { [weak self] event in self?.handle(event) }
    }

    /// Starts the display assertion immediately, then registers and starts the
    /// privileged helper if macOS has approved it.
    func start() {
        guard !isStarted else { return }
        generation &+= 1
        let run = generation
        isStarted = true
        isStopping = false
        acquireDisplayAssertion()
        setStatus("Starting closed-lid keep awake…")

        enqueue { [weak self] in
            guard let self, self.generation == run else { return }
            let serviceStatus = self.client.prepare()
            await self.handlePreparation(serviceStatus, run: run, openSettingsIfNeeded: false)
        }
    }

    /// Releases the local display assertion immediately, then stops the helper in operation order.
    func stop() {
        guard isStarted || assertionID != nil else { return }
        generation &+= 1
        let stopGeneration = generation
        isStarted = false
        helperSessionStarted = false
        isStopping = true
        releaseDisplayAssertion()
        setStatus("Stopping keep awake…")

        enqueue { [weak self] in
            guard let self, self.generation == stopGeneration else { return }
            await self.client.end()
            guard self.generation == stopGeneration else { return }
            self.isStopping = false
            self.setStatus("Closed-lid keep awake is off")
        }
    }

    /// Registers the helper and opens Login Items when macOS needs the user to approve it.
    /// If Alarm mode is already active, approval immediately starts the helper session.
    func prepareLidClosed() {
        let run = generation
        enqueue { [weak self] in
            guard let self, self.generation == run else { return }
            let serviceStatus = self.client.prepare()
            await self.handlePreparation(serviceStatus, run: run, openSettingsIfNeeded: true)
        }
    }

    /// Re-checks an outstanding Login Items approval after the app returns to the foreground.
    /// This does not register again or reopen System Settings; it only starts the session once
    /// macOS reports that the already registered service is enabled.
    func refreshApproval() {
        guard isStarted, !helperSessionStarted, client.status == .enabled else { return }
        let run = generation
        enqueue { [weak self] in
            guard let self, self.generation == run, self.isStarted, !self.helperSessionStarted else { return }
            await self.handlePreparation(.enabled, run: run, openSettingsIfNeeded: false)
        }
    }

    /// Used during app termination: invalidating the owner connection makes launchd's
    /// helper restore the system setting even if the app cannot await an XPC reply.
    func terminate() {
        generation &+= 1
        isStarted = false
        isStopping = false
        helperSessionStarted = false
        client.disconnect()
        releaseDisplayAssertion()
        setStatus("Closed-lid keep awake is off")
    }

    private func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        let previous = operationTask
        operationTask = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func handlePreparation(
        _ serviceStatus: PowerHelperStatus,
        run: UInt64,
        openSettingsIfNeeded: Bool
    ) async {
        guard generation == run else { return }
        switch serviceStatus {
        case .enabled:
            if isStarted {
                await beginHelperSession(run: run)
            } else {
                setStatus("Closed-lid keep awake is ready for Alarm mode")
            }
        case .requiresApproval:
            setStatus("Approve Screen Privacy in System Settings → Login Items for closed-lid keep awake")
            if openSettingsIfNeeded { client.openApprovalSettings() }
        case .notRegistered:
            setStatus("Screen Privacy could not register the closed-lid helper")
        case let .unavailable(message):
            setStatus("Closed-lid keep awake unavailable · \(message)")
        }
    }

    private func beginHelperSession(run: UInt64) async {
        guard generation == run, isStarted else { return }
        setStatus("Starting closed-lid helper…")
        do {
            try await client.begin(endsAt: nil)
            guard generation == run, isStarted else { return }
            helperSessionStarted = true
            setStatus("Closed-lid keep awake is active")
        } catch {
            guard generation == run else { return }
            helperSessionStarted = false
            setStatus("Closed-lid keep awake unavailable · \(error.localizedDescription)")
        }
    }

    private func handle(_ event: PowerHelperEvent) {
        switch event {
        case let .sessionEnded(reason):
            guard helperSessionStarted else { return }
            helperSessionStarted = false
            setStatus("Closed-lid keep awake stopped · \(reason)")
            onSafetyStop?(reason)
        case .connectionLost:
            guard helperSessionStarted else { return }
            helperSessionStarted = false
            setStatus("Closed-lid helper connection lost")
            onSafetyStop?("closed-lid helper connection lost")
        }
    }

    private func acquireDisplayAssertion() {
        guard assertionID == nil else { return }
        var identifier = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Screen Privacy alarm is active" as CFString,
            &identifier
        )
        if result == kIOReturnSuccess {
            assertionID = identifier
            assertionFailure = nil
        } else {
            assertionFailure = "display sleep prevention unavailable"
        }
        onStatusChange?()
    }

    private func releaseDisplayAssertion() {
        guard let assertionID else { return }
        IOPMAssertionRelease(assertionID)
        self.assertionID = nil
    }

    private func setStatus(_ message: String) {
        let updated = assertionFailure.map { "\(message) · \($0)" } ?? message
        guard statusText != updated else { return }
        statusText = updated
        onStatusChange?()
    }
}
