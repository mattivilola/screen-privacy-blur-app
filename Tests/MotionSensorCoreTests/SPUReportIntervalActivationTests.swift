import Foundation
import XCTest
@testable import MotionSensorCore

@MainActor
final class SPUReportIntervalActivationTests: XCTestCase {
    private let identity = SPUReportIntervalIdentity(bootIdentity: "boot-a", driverRegistryID: 42)
    private let numberType = CFNumberType.sInt32Type.rawValue

    func testJournalMustBeSavedBeforeIntervalIsChanged() {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        journal.failSave = true
        let activation = SPUReportIntervalActivation(store: store, journal: journal)

        XCTAssertThrowsError(try activation.activate())
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(journal.leaseHeld)
    }

    func testFailedActivationWriteAttemptsToRestoreOriginalValue() {
        let store = MockIntervalStore(identity: identity)
        store.failNextWrites.insert(SPUReportIntervalActivation.enabledInterval)
        let journal = MockIntervalJournal()
        let activation = SPUReportIntervalActivation(store: store, journal: journal)

        XCTAssertThrowsError(try activation.activate())

        XCTAssertEqual(store.writes, [1_000, 0])
        XCTAssertNil(journal.record)
        XCTAssertFalse(journal.leaseHeld)
    }

    func testRestoreFailureRetainsJournalAndLeaseForRetry() throws {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        let activation = SPUReportIntervalActivation(store: store, journal: journal)
        try activation.activate()
        store.failNextWrites.insert(0)

        XCTAssertThrowsError(try activation.restore())
        XCTAssertNotNil(journal.record)
        XCTAssertTrue(journal.leaseHeld)
        XCTAssertTrue(activation.hasPendingRestore)

        try activation.restore()
        XCTAssertEqual(store.writes, [1_000, 0, 0])
        XCTAssertNil(journal.record)
        XCTAssertFalse(journal.leaseHeld)
    }

    func testStaleBootOrDriverRecordIsDiscardedWithoutReplayingItsValue() throws {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        journal.record = SPUReportIntervalJournalRecord(
            identity: SPUReportIntervalIdentity(bootIdentity: "old-boot", driverRegistryID: 42),
            original: SPUReportIntervalValue(value: 0, cfNumberType: numberType),
            intendedValue: 1_000
        )
        let activation = SPUReportIntervalActivation(store: store, journal: journal)

        try activation.activate()

        XCTAssertEqual(store.writes, [1_000])
        XCTAssertEqual(journal.record?.identity, identity)
        XCTAssertTrue(journal.leaseHeld)
        try activation.restore()
        XCTAssertEqual(store.writes, [1_000, 0])
    }

    func testNonzeroOriginalIntervalIsRefusedWithoutWriting() {
        let store = MockIntervalStore(identity: identity, value: 5)
        let journal = MockIntervalJournal()
        let activation = SPUReportIntervalActivation(store: store, journal: journal)

        XCTAssertThrowsError(try activation.activate())
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNil(journal.record)
        XCTAssertFalse(journal.leaseHeld)
    }

    func testMalformedRecoveryRecordIsRetainedAndNeverReplayed() {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        journal.record = SPUReportIntervalJournalRecord(
            identity: identity,
            original: SPUReportIntervalValue(value: 77, cfNumberType: numberType),
            intendedValue: 1_000
        )
        let activation = SPUReportIntervalActivation(store: store, journal: journal)

        XCTAssertThrowsError(try activation.activate())

        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNotNil(journal.record)
        XCTAssertTrue(journal.leaseHeld)
        XCTAssertTrue(activation.hasPendingRestore)
        XCTAssertThrowsError(try activation.restore())
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNotNil(journal.record)
        XCTAssertTrue(journal.leaseHeld)
    }

    func testRecoveryOnlyDoesNotResolveStoreOrWriteWithoutJournal() throws {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        var resolvedStore = false

        try SPUReportIntervalActivation.recoverPendingOnly(journal: journal) {
            resolvedStore = true
            return store
        }

        XCTAssertFalse(resolvedStore)
        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertFalse(journal.leaseHeld)
    }

    func testRecoveryOnlyRestoresMatchingRecordWithoutActivating() throws {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        journal.record = SPUReportIntervalJournalRecord(
            identity: identity,
            original: SPUReportIntervalValue(value: 0, cfNumberType: numberType),
            intendedValue: 1_000
        )

        try SPUReportIntervalActivation.recoverPendingOnly(journal: journal) { store }

        XCTAssertEqual(store.writes, [0])
        XCTAssertNil(journal.record)
        XCTAssertFalse(journal.leaseHeld)
    }

    func testRecoveryOnlyDiscardsStaleIdentityWithoutWriting() throws {
        let store = MockIntervalStore(identity: identity)
        let journal = MockIntervalJournal()
        journal.record = SPUReportIntervalJournalRecord(
            identity: SPUReportIntervalIdentity(bootIdentity: "old-boot", driverRegistryID: 42),
            original: SPUReportIntervalValue(value: 0, cfNumberType: numberType),
            intendedValue: 1_000
        )

        try SPUReportIntervalActivation.recoverPendingOnly(journal: journal) { store }

        XCTAssertTrue(store.writes.isEmpty)
        XCTAssertNil(journal.record)
        XCTAssertFalse(journal.leaseHeld)
    }
}

private final class MockIntervalStore: SPUReportIntervalStore {
    let identity: SPUReportIntervalIdentity
    var value: Int64
    var writes: [Int64] = []
    var failNextWrites: Set<Int64> = []

    init(identity: SPUReportIntervalIdentity, value: Int64 = 0) {
        self.identity = identity
        self.value = value
    }

    func read() throws -> SPUReportIntervalValue {
        SPUReportIntervalValue(value: value, cfNumberType: CFNumberType.sInt32Type.rawValue)
    }

    func write(_ value: Int64, preserving numberType: Int) throws {
        writes.append(value)
        if failNextWrites.remove(value) != nil {
            throw SPUReportIntervalActivationError.propertyWrite(-1)
        }
        self.value = value
    }
}

private final class MockIntervalJournal: SPUReportIntervalJournal {
    var record: SPUReportIntervalJournalRecord?
    var leaseHeld = false
    var failSave = false

    func acquireLease() throws {
        guard !leaseHeld else { throw SPUReportIntervalActivationError.leaseUnavailable }
        leaseHeld = true
    }

    func releaseLease() { leaseHeld = false }

    func load() throws -> SPUReportIntervalJournalRecord? { record }

    func save(_ record: SPUReportIntervalJournalRecord) throws {
        if failSave { throw SPUReportIntervalActivationError.journal("mock save failure") }
        self.record = record
    }

    func remove() throws { record = nil }
}
