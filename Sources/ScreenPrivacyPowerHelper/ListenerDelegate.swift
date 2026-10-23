import Foundation
import PowerHelperKit

/// Accepts a connection only from our own signed app (the listener enforces the code-signing requirement
/// before this is asked) and exports the single-purpose helper interface on it.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let coordinator: PowerHelperCoordinator

    init(coordinator: PowerHelperCoordinator) {
        self.coordinator = coordinator
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ScreenPrivacyPowerHelperProtocol.self)
        newConnection.exportedObject = ConnectionHandler(connection: newConnection, coordinator: coordinator)
        newConnection.remoteObjectInterface = NSXPCInterface(with: ScreenPrivacyPowerHelperClientProtocol.self)

        let coordinator = coordinator
        // The connection going away (app quit or crash) ends the session it owns.
        let ended: @Sendable (ConnectionBox) -> Void = { box in
            Task { @MainActor in coordinator.connectionEnded(box.connection) }
        }
        newConnection.invalidationHandler = { [weak newConnection] in
            if let newConnection {
                ended(ConnectionBox(newConnection))
            }
        }
        newConnection.interruptionHandler = { [weak newConnection] in
            if let newConnection {
                ended(ConnectionBox(newConnection))
            }
        }
        newConnection.resume()
        return true
    }
}

/// Carries a connection to the main actor, where the coordinator only ever compares it by identity or messages it.
struct ConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

/// Used when the build carries no team identifier, so there is no signing requirement to hold clients to.
final class RefusingListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        false
    }
}

private final class ConnectionHandler: NSObject, ScreenPrivacyPowerHelperProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let coordinator: PowerHelperCoordinator

    init(connection: NSXPCConnection, coordinator: PowerHelperCoordinator) {
        self.connection = connection
        self.coordinator = coordinator
    }

    func beginLidClosedSession(endsAt: Date?, reply: @escaping @Sendable (Bool, String?) -> Void) {
        let coordinator = coordinator
        let box = connection.map(ConnectionBox.init)
        Task { @MainActor in
            guard let box else {
                reply(false, "The connection closed.")
                return
            }
            let result = coordinator.begin(for: box.connection, endsAt: endsAt)
            reply(result.success, result.message)
        }
    }

    func endLidClosedSession(reply: @escaping @Sendable () -> Void) {
        let coordinator = coordinator
        let box = connection.map(ConnectionBox.init)
        Task { @MainActor in
            if let box {
                coordinator.end(for: box.connection)
            }
            reply()
        }
    }
}
