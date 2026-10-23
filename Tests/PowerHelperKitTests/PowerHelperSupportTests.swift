import Foundation
@testable import PowerHelperKit
import Testing

struct PowerHelperSupportTests {
    @Test
    func labelsDifferBetweenDevAndReleaseBuilds() {
        #expect(PowerHelperIdentity.label(appBundleIdentifier: "com.iloapps.screenprivacy") == "com.iloapps.screenprivacy.PowerHelper")
        #expect(PowerHelperIdentity.label(appBundleIdentifier: "com.iloapps.screenprivacy.dev") == "com.iloapps.screenprivacy.dev.PowerHelper")
        #expect(PowerHelperIdentity.launchdPlistName(label: "a.b.PowerHelper") == "a.b.PowerHelper.plist")
    }

    @Test
    func requirementsNameTheIdentifierAndTheTeam() {
        let client = PowerHelperIdentity.clientCodeSigningRequirement(
            appBundleIdentifier: "com.iloapps.screenprivacy",
            teamIdentifier: "MM233FKU38"
        )
        #expect(client == "anchor apple generic and identifier \"com.iloapps.screenprivacy\" and certificate leaf[subject.OU] = \"MM233FKU38\"")

        let helper = PowerHelperIdentity.helperCodeSigningRequirement(
            helperLabel: "com.iloapps.screenprivacy.PowerHelper",
            teamIdentifier: "MM233FKU38"
        )
        #expect(helper?.contains("identifier \"com.iloapps.screenprivacy.PowerHelper\"") == true)
    }

    @Test
    func requirementsAreRefusedWithoutAValidTeamOrIdentifier() {
        #expect(PowerHelperIdentity.clientCodeSigningRequirement(appBundleIdentifier: "com.iloapps.screenprivacy", teamIdentifier: "") == nil)
        #expect(PowerHelperIdentity.clientCodeSigningRequirement(appBundleIdentifier: "com.iloapps.screenprivacy", teamIdentifier: "short") == nil)
        #expect(PowerHelperIdentity.clientCodeSigningRequirement(appBundleIdentifier: "", teamIdentifier: "MM233FKU38") == nil)
        #expect(PowerHelperIdentity.clientCodeSigningRequirement(appBundleIdentifier: "a\" or anchor apple or \"b", teamIdentifier: "MM233FKU38") == nil)
        #expect(PowerHelperIdentity.helperCodeSigningRequirement(helperLabel: "x y", teamIdentifier: "MM233FKU38") == nil)
    }

    @Test
    func pmsetOutputIsParsedForTheSleepDisabledLine() throws {
        let enabled = " System-wide power settings:\n SleepDisabled\t\t1\n Currently in use:\n sleep 1\n"
        let disabled = " System-wide power settings:\n SleepDisabled\t\t0\n"
        #expect(try PmsetSleepDisabledSetting.parseSleepDisabled(enabled))
        #expect(try PmsetSleepDisabledSetting.parseSleepDisabled(disabled) == false)
        #expect(throws: PmsetSleepDisabledSetting.OutputError.missingSleepDisabled) {
            try PmsetSleepDisabledSetting.parseSleepDisabled(" sleep 1\n displaysleep 10\n")
        }
        #expect(throws: PmsetSleepDisabledSetting.OutputError.missingSleepDisabled) {
            try PmsetSleepDisabledSetting.parseSleepDisabled("")
        }
        #expect(throws: PmsetSleepDisabledSetting.OutputError.invalidSleepDisabledValue("maybe")) {
            try PmsetSleepDisabledSetting.parseSleepDisabled("SleepDisabled maybe\n")
        }
    }

    @Test
    func fileJournalRoundTripsAndDeletes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("helper", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let journal = FileKeepAwakeJournal(directoryURL: directory)
        let record = KeepAwakeJournalRecord(priorSleepDisabled: false, endsAt: Date(timeIntervalSince1970: 1_800_000_000))

        #expect(try journal.load() == nil)
        try journal.save(record)
        #expect(try journal.load() == record)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(FileKeepAwakeJournal.fileName).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o644)

        try journal.delete()
        #expect(try journal.load() == nil)
        try journal.delete()
    }

    @Test
    func defaultJournalDirectoryIsUnderLibraryApplicationSupport() {
        #expect(FileKeepAwakeJournal.defaultDirectoryURL(label: "a.b.PowerHelper").path == "/Library/Application Support/a.b.PowerHelper")
    }

    @Test
    func launchdRestartsAfterUnsuccessfulExitAndUsesTheEmbeddedHelper() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repositoryRoot
            .appendingPathComponent("Packaging/com.iloapps.screenprivacy.PowerHelper.plist")
        let data = try Data(contentsOf: plistURL)
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(value as? [String: Any])
        let keepAlive = try #require(plist["KeepAlive"] as? [String: Any])

        #expect(keepAlive["SuccessfulExit"] as? Bool == false)
        #expect(plist["ThrottleInterval"] as? Int == 10)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["BundleProgram"] as? String == "Contents/Library/HelperTools/ScreenPrivacyPowerHelper")
    }
}
