import XCTest
import AppKit
@testable import ScreenPrivacy

@MainActor
final class AlarmAudioTests: XCTestCase {
    func testSirenIsValidTwoSecondMonoPCM() async {
        let wav = AlarmAudio.sirenData()
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<16], as: UTF8.self), "WAVEfmt ")
        XCTAssertEqual(wav.count, 44 + 22_050 * 2 * 2)
        XCTAssertNotNil(NSSound(data: wav))
    }
    func testJournalPrecedesMutationAndRepeatedStartPreservesOriginalSnapshot() async throws {
        let journal = MemoryJournal(); let backend = MockAudio(journal)
        let audio = AlarmAudio(backend: backend, journal: journal)
        try audio.start(volume: 1); let saved = journal.data
        try audio.start(volume: 0.5)
        XCTAssertEqual(journal.data, saved); XCTAssertEqual(backend.snapshotCount, 1)
        audio.restore()
        XCTAssertTrue(backend.sound.stopped); XCTAssertNil(journal.data)
        XCTAssertEqual(backend.restoredUID, "speaker-original")
        XCTAssertFalse(backend.guarded)
    }
    func testFailedJournalWriteNeverChangesAudio() async {
        let journal = MemoryJournal(); journal.failSave = true
        let backend = MockAudio(journal); let audio = AlarmAudio(backend: backend, journal: journal)
        XCTAssertThrowsError(try audio.start(volume: 1))
        XCTAssertFalse(backend.maximized)
    }
    func testPartialDeviceFailureRestoresAndPlaybackFailureRestores() async {
        for failAtPlay in [false, true] {
            let journal = MemoryJournal(); let backend = MockAudio(journal)
            backend.failMaximize = !failAtPlay; backend.failPlay = failAtPlay
            let audio = AlarmAudio(backend: backend, journal: journal)
            XCTAssertThrowsError(try audio.start(volume: 1))
            XCTAssertEqual(backend.restoredUID, "speaker-original"); XCTAssertNil(journal.data)
        }
    }
    func testOutputRouteChangeStopsAndRestoresOriginalDevice() async throws {
        let journal = MemoryJournal(); let backend = MockAudio(journal)
        let audio = AlarmAudio(backend: backend, journal: journal)
        try audio.start(volume: 1)
        backend.currentUID = "headphones"
        XCTAssertThrowsError(try audio.start(volume: 1))
        XCTAssertTrue(backend.sound.stopped)
        XCTAssertEqual(backend.restoredUID, "speaker-original")
    }
    func testMissingDeviceKeepsJournalAndRecoveryUsesGuardedRestore() async throws {
        let journal = MemoryJournal(); let backend = MockAudio(journal)
        let audio = AlarmAudio(backend: backend, journal: journal)
        try audio.start(volume: 1)
        backend.canRestore = false; audio.restore(); XCTAssertTrue(audio.restorationPending)
        let relaunched = AlarmAudio(backend: backend, journal: journal)
        backend.canRestore = true; relaunched.recoverPreviousVolume()
        XCTAssertTrue(backend.guarded); XCTAssertNil(journal.data)
    }
}

@MainActor
private final class MemoryJournal: AlarmAudioJournal {
    var data: Data?
    var failSave = false
    func load() -> Data? { data }
    func save(_ data: Data) throws { if failSave { throw MockError.failed }; self.data = data }
    func clear() throws { data = nil }
}
private enum MockError: Error { case failed }
@MainActor
private final class MockSound: AlarmSoundPlaying {
    var volume: Float = 1
    var stopped = false
    @discardableResult func stop() -> Bool { stopped = true; return true }
}
@MainActor
private final class MockAudio: AlarmAudioBackend {
    let journal: MemoryJournal
    let sound = MockSound()
    var snapshotCount = 0, maximized = false, failMaximize = false, failPlay = false, canRestore = true, guarded = false
    var currentUID = "speaker-original"
    var restoredUID: String?
    init(_ journal: MemoryJournal) { self.journal = journal }
    func speakerUID() throws -> String { currentUID }
    func snapshot(uid: String) throws -> [AlarmAudioProperty] {
        snapshotCount += 1
        return [AlarmAudioProperty(selector: 1, element: 0, bytes: Data([1, 2, 3, 4]))]
    }
    func maximize(uid: String, properties: [AlarmAudioProperty]) throws {
        XCTAssertNotNil(journal.data); maximized = true
        if failMaximize { throw MockError.failed }
    }
    func restore(uid: String, properties: [AlarmAudioProperty], guarded: Bool) -> Bool {
        restoredUID = uid; self.guarded = guarded; return canRestore
    }
    func play(data: Data, uid: String, volume: Double) throws -> any AlarmSoundPlaying {
        if failPlay { throw MockError.failed }; return sound
    }
}
