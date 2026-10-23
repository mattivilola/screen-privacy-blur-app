import Foundation
import PowerHelperKit

/// What the helper knows about itself, read from the Info.plist embedded in its binary at build time.
struct HelperConfiguration {
    /// The helper's launchd label and Mach service name (its own bundle identifier).
    let label: String
    let clientBundleIdentifier: String
    let teamIdentifier: String

    static func load(from bundle: Bundle = .main) -> HelperConfiguration {
        HelperConfiguration(
            label: bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String ?? "",
            clientBundleIdentifier: bundle.object(forInfoDictionaryKey: "ScreenPrivacyClientBundleIdentifier") as? String ?? "",
            teamIdentifier: bundle.object(forInfoDictionaryKey: "ScreenPrivacyTeamIdentifier") as? String ?? ""
        )
    }

    /// Nil when the build has no team or identifiers, so the helper refuses every client.
    var clientCodeSigningRequirement: String? {
        PowerHelperIdentity.clientCodeSigningRequirement(
            appBundleIdentifier: clientBundleIdentifier,
            teamIdentifier: teamIdentifier
        )
    }
}
