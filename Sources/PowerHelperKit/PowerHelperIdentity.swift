import Foundation

/// Names, thresholds and code-signing requirements shared by the app and the helper.
public enum PowerHelperIdentity {
    /// The helper's launchd label and Mach service name are the app's bundle identifier plus this suffix, so
    /// the dev and release builds (which have different bundle identifiers) can coexist.
    public static let labelSuffix = ".PowerHelper"

    /// The session ends when the battery is at or below this percentage and the Mac is not on AC power.
    public static let batteryFloorPercent = 10

    public static func label(appBundleIdentifier: String) -> String {
        appBundleIdentifier + labelSuffix
    }

    /// The file name of the launchd property list inside the app's `Contents/Library/LaunchDaemons`.
    public static func launchdPlistName(label: String) -> String {
        label + ".plist"
    }

    /// The code-signing requirement the helper puts on its clients: our app, signed by our team.
    /// Nil when either value is missing or not a plain identifier, so a build without a team refuses every client.
    public static func clientCodeSigningRequirement(appBundleIdentifier: String, teamIdentifier: String) -> String? {
        requirement(identifier: appBundleIdentifier, teamIdentifier: teamIdentifier)
    }

    /// The code-signing requirement the app puts on the helper it talks to.
    public static func helperCodeSigningRequirement(helperLabel: String, teamIdentifier: String) -> String? {
        requirement(identifier: helperLabel, teamIdentifier: teamIdentifier)
    }

    private static func requirement(identifier: String, teamIdentifier: String) -> String? {
        guard isPlainIdentifier(identifier), isTeamIdentifier(teamIdentifier) else {
            return nil
        }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Reverse-DNS characters only, so a value can never break out of the quoted requirement string.
    static func isPlainIdentifier(_ value: String) -> Bool {
        value.isEmpty == false && value.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "." || scalar == "-"
        }
    }

    static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy { scalar in
            ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
    }
}
