import Foundation
import PowerHelperKit
import ServiceManagement

/// Where the privileged power helper stands, from the app's point of view.
public enum PowerHelperStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case unavailable(String)
}

public enum PowerHelperEvent: Equatable, Sendable {
    /// The helper ended the session on its own (deadline, low battery, heat). The text is a short reason.
    case sessionEnded(reason: String)
    /// The connection to the helper dropped. The helper puts sleep back by itself when that happens.
    case connectionLost
}

public struct PowerHelperError: Error, Equatable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

/// Registers and authenticates the privileged helper, then keeps one XPC connection for the session lifetime.
@MainActor
public protocol PowerHelperControlling: AnyObject {
    var status: PowerHelperStatus { get }
    var eventHandler: (@MainActor (PowerHelperEvent) -> Void)? { get set }

    /// Registers the helper with the system when that has not happened yet, then reports the status.
    func prepare() -> PowerHelperStatus
    /// Starts a lid-closed session, or moves the deadline of the running one. Nil `endsAt` runs until `end()`.
    func begin(endsAt: Date?) async throws
    func end() async
    func openApprovalSettings()
}

/// The registration boundary, kept separate so tests never register a real root daemon.
@MainActor
protocol PowerHelperServiceManaging {
    var status: SMAppService.Status { get }
    func register() throws
}

extension SMAppService: PowerHelperServiceManaging {}

/// The app's side of the privileged power helper: registers the launchd daemon (`SMAppService`) and talks to it
/// over one XPC connection that lives as long as the session, because the helper ends a session when its
/// owner disconnects.
@MainActor
public final class PowerHelperClient: PowerHelperControlling {
    public var eventHandler: (@MainActor (PowerHelperEvent) -> Void)?

    private let helperLabel: String
    private let teamIdentifier: String
    private let service: any PowerHelperServiceManaging
    private var connection: NSXPCConnection?
    private var connectionID: UUID?

    /// - Parameters:
    ///   - appBundleIdentifier: The app's bundle identifier; the helper's label is derived from it.
    ///   - teamIdentifier: The team the app and helper are signed with. Without one there is nothing to trust.
    public convenience init(
        appBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        teamIdentifier: String? = Bundle.main.object(forInfoDictionaryKey: "ScreenPrivacyTeamIdentifier") as? String
    ) {
        let label = PowerHelperIdentity.label(appBundleIdentifier: appBundleIdentifier ?? "")
        self.init(
            appBundleIdentifier: appBundleIdentifier,
            teamIdentifier: teamIdentifier,
            service: SMAppService.daemon(plistName: PowerHelperIdentity.launchdPlistName(label: label))
        )
    }

    init(
        appBundleIdentifier: String?,
        teamIdentifier: String?,
        service: any PowerHelperServiceManaging
    ) {
        helperLabel = PowerHelperIdentity.label(appBundleIdentifier: appBundleIdentifier ?? "")
        self.teamIdentifier = teamIdentifier ?? ""
        self.service = service
    }

    public var status: PowerHelperStatus {
        guard helperRequirement != nil else {
            return .unavailable("This build has no valid signing team, so closed-lid keep awake is unavailable.")
        }
        switch service.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notRegistered, .notFound:
            // A service lookup is not a bundle-content check. In particular, a new helper can be
            // absent from Service Management until register() submits its bundled plist. Let that
            // call validate the install and report its real error instead of skipping registration.
            return .notRegistered
        @unknown default:
            return .unavailable("The closed-lid helper is in an unknown state.")
        }
    }

    public func prepare() -> PowerHelperStatus {
        let current = status
        guard current == .notRegistered else {
            return current
        }
        do {
            try service.register()
        } catch {
            // Registering can report an error while the approval is still pending; the status tells which.
            let afterwards = status
            if afterwards == .notRegistered {
                return .unavailable(error.localizedDescription)
            }
            return afterwards
        }
        let afterwards = status
        if afterwards == .notRegistered {
            return .unavailable("macOS couldn't find the closed-lid helper after registration. Quit and reopen Screen Privacy, then try again.")
        }
        return afterwards
    }

    public func begin(endsAt: Date?) async throws {
        let proxy = try makeProxy()
        let result: (Bool, String?)
        do {
            result = try await proxy.call { proxy, reply in
                proxy.beginLidClosedSession(endsAt: endsAt) { success, message in
                    reply(.success((success, message)))
                }
            }
        } catch {
            // A timeout invalidates this connection. Clear the client-side reference before a later retry.
            disconnect()
            throw error
        }
        guard result.0 else {
            throw PowerHelperError(result.1 ?? "The helper couldn't keep the Mac awake with its lid closed.")
        }
    }

    public func end() async {
        guard let connection else {
            return
        }
        // Closing the connection is what ends a session for good, even if the polite request never arrives.
        defer { disconnect() }
        guard let proxy = try? makeProxy(existing: connection) else {
            return
        }
        let _: Void? = try? await proxy.call { proxy, reply in
            proxy.endLidClosedSession {
                reply(.success(()))
            }
        }
    }

    /// Immediately drops the session connection. The helper treats this like app termination and restores
    /// `SleepDisabled`; this synchronous path also works from `applicationWillTerminate`.
    public func disconnect() {
        guard let connection else { return }
        self.connection = nil
        connectionID = nil
        connection.invalidate()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Connection

    private var helperRequirement: String? {
        PowerHelperIdentity.helperCodeSigningRequirement(helperLabel: helperLabel, teamIdentifier: teamIdentifier)
    }

    private func makeProxy(existing: NSXPCConnection? = nil) throws -> HelperProxy {
        let activeConnection: NSXPCConnection
        if let existing {
            activeConnection = existing
        } else if let connection {
            activeConnection = connection
        } else {
            activeConnection = try openConnection()
            connection = activeConnection
        }
        return HelperProxy(connection: activeConnection)
    }

    private func openConnection() throws -> NSXPCConnection {
        guard let requirement = helperRequirement else {
            throw PowerHelperError("This build has no valid signing team, so closed-lid keep awake is unavailable.")
        }
        let newConnection = NSXPCConnection(machServiceName: helperLabel, options: .privileged)
        newConnection.remoteObjectInterface = NSXPCInterface(with: ScreenPrivacyPowerHelperProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: ScreenPrivacyPowerHelperClientProtocol.self)
        newConnection.exportedObject = ClientCallbacks { [weak self] reason in
            Task { @MainActor in
                self?.eventHandler?(.sessionEnded(reason: reason))
            }
        }
        newConnection.setCodeSigningRequirement(requirement)

        // Older SDKs do not mark NSXPCConnection as Sendable. Carry a value identifying this
        // connection across the callback boundary and only touch the connection on the main actor.
        let connectionID = UUID()
        self.connectionID = connectionID
        let dropped: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == connectionID, self.connection != nil else {
                    return
                }
                self.connection = nil
                self.connectionID = nil
                self.eventHandler?(.connectionLost)
            }
        }
        newConnection.invalidationHandler = dropped
        newConnection.interruptionHandler = dropped
        newConnection.resume()
        return newConnection
    }
}

/// Receives the helper's "I ended the session" call on the app's side of the connection.
private final class ClientCallbacks: NSObject, ScreenPrivacyPowerHelperClientProtocol, @unchecked Sendable {
    private let onSessionEnded: @Sendable (String) -> Void

    init(onSessionEnded: @escaping @Sendable (String) -> Void) {
        self.onSessionEnded = onSessionEnded
    }

    func lidClosedSessionEnded(reason: String) {
        onSessionEnded(reason)
    }
}

/// Turns one helper call into an async call that finishes exactly once, with the reply or the connection error.
@MainActor
private struct HelperProxy {
    let connection: NSXPCConnection

    func call<Value: Sendable>(
        _ body: (any ScreenPrivacyPowerHelperProtocol, @escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        try await boundedHelperReply(onTimeout: { connection.invalidate() }) { reply in
            let object = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                reply(.failure(PowerHelperError("Couldn't reach the lid-closed helper: \(error.localizedDescription)")))
            }
            guard let proxy = object as? any ScreenPrivacyPowerHelperProtocol else {
                reply(.failure(PowerHelperError("Couldn't reach the lid-closed helper.")))
                return
            }
            body(proxy, reply)
        }
    }
}

/// The same deadline gate serves real XPC and tests with a transport that never replies.
@MainActor
func boundedHelperReply<Value: Sendable>(
    timeout: Duration = .seconds(5),
    onTimeout: @escaping @MainActor @Sendable () -> Void,
    request: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let gate = ResumeOnce(continuation)
        let task = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            if gate.resume(.failure(PowerHelperError("The lid-closed helper request timed out."))) { onTimeout() }
        }
        gate.installTimeout(task)
        request { gate.resume($0) }
    }
}

/// XPC calls its error handler or its reply, never both for one call, but a continuation must never resume twice.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func installTimeout(_ task: Task<Void, Never>) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        timeoutTask = task
        lock.unlock()
    }

    @discardableResult
    func resume(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard let pending = continuation else {
            lock.unlock()
            return false
        }
        continuation = nil
        let timeout = timeoutTask
        timeoutTask = nil
        lock.unlock()
        timeout?.cancel()
        pending.resume(with: result)
        return true
    }
}
