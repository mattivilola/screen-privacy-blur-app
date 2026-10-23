import Foundation

/// The helper's journal: one tiny JSON file in a root-owned folder under `/Library/Application Support`.
public struct FileKeepAwakeJournal: KeepAwakeJournal {
    public static let fileName = "lid-closed-session.json"

    private let directoryURL: URL
    private let fileURL: URL

    /// The journal folder for a helper label, `/Library/Application Support/<label>`.
    public static func defaultDirectoryURL(label: String) -> URL {
        URL(fileURLWithPath: "/Library/Application Support", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        fileURL = directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    public func load() throws -> KeepAwakeJournalRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KeepAwakeJournalRecord.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ record: KeepAwakeJournalRecord) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}
