import Foundation
import PowerHelperKit
import os

// The privileged power helper. It does exactly one thing: it holds the global `SleepDisabled` power setting
// on while the Screen Privacy app asks for it, and puts it back afterwards. It has no network access.

let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ScreenPrivacyPowerHelper", category: "main")
let configuration = HelperConfiguration.load()

guard configuration.label.isEmpty == false else {
    logger.fault("The helper has no embedded Info.plist; exiting.")
    exit(EXIT_FAILURE)
}

let coordinator = PowerHelperCoordinator(
    journal: FileKeepAwakeJournal(directoryURL: FileKeepAwakeJournal.defaultDirectoryURL(label: configuration.label))
)
coordinator.start()

let listener = NSXPCListener(machServiceName: configuration.label)
let delegate: any NSXPCListenerDelegate
if let requirement = configuration.clientCodeSigningRequirement {
    listener.setConnectionCodeSigningRequirement(requirement)
    delegate = ListenerDelegate(coordinator: coordinator)
} else {
    logger.fault("No team identifier in this build; refusing every client.")
    delegate = RefusingListenerDelegate()
}

listener.delegate = delegate
listener.resume()

// Restore the sleep setting when launchd stops the helper (shutdown, update, unregister).
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler {
    MainActor.assumeIsolated {
        coordinator.prepareForTermination()
    }
    exit(EXIT_SUCCESS)
}

terminationSource.resume()

// `RunLoop.main` also serves the main dispatch queue and the power-source run loop source.
RunLoop.main.run()
