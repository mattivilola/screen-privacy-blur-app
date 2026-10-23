import CoreFoundation
import Foundation
import IOKit
import Darwin

struct SPUReportIntervalIdentity: Codable, Equatable, Sendable {
    let bootIdentity: String
    let driverRegistryID: UInt64
}

struct SPUReportIntervalValue: Codable, Equatable, Sendable {
    let value: Int64
    let cfNumberType: Int
}

struct SPUReportIntervalJournalRecord: Codable, Equatable, Sendable {
    let identity: SPUReportIntervalIdentity
    let original: SPUReportIntervalValue
    let intendedValue: Int64
}

enum SPUReportIntervalActivationError: Error, LocalizedError, Equatable {
    case leaseUnavailable
    case journal(String)
    case identityUnavailable
    case missingOrUnreadableProperty
    case unexpectedOriginalValue(Int64)
    case unsupportedNumberType(Int)
    case propertyWrite(Int32)
    case restoreFailed(String)

    var errorDescription: String? {
        switch self {
        case .leaseUnavailable: "Another Screen Privacy process is managing the SPU accelerometer."
        case let .journal(message): "The SPU interval recovery record could not be managed: \(message)"
        case .identityUnavailable: "The SPU accelerometer identity could not be verified."
        case .missingOrUnreadableProperty: "The SPU accelerometer interval property is missing or unreadable."
        case let .unexpectedOriginalValue(value): "The SPU accelerometer interval was already set to \(value); activation was refused."
        case let .unsupportedNumberType(type): "The SPU accelerometer interval uses unsupported numeric type \(type)."
        case let .propertyWrite(code): "The SPU accelerometer interval could not be written (IOKit \(String(format: "0x%08x", UInt32(bitPattern: code))))."
        case let .restoreFailed(message): "The SPU accelerometer interval could not be restored: \(message)"
        }
    }
}

protocol SPUReportIntervalStore: AnyObject {
    var identity: SPUReportIntervalIdentity { get }
    func read() throws -> SPUReportIntervalValue
    func write(_ value: Int64, preserving numberType: Int) throws
}

protocol SPUReportIntervalJournal: AnyObject {
    func acquireLease() throws
    func releaseLease()
    func load() throws -> SPUReportIntervalJournalRecord?
    func save(_ record: SPUReportIntervalJournalRecord) throws
    func remove() throws
}

/// Owns one explicitly reversible, fixed-value change to the accelerometer's ReportInterval.
/// It never writes ReportingState or PowerState and never accepts a property/service name.
@MainActor
final class SPUReportIntervalActivation {
    static let enabledInterval: Int64 = 1_000
    private static var retainedRecovery: SPUReportIntervalActivation?
    private static var retainedJournalLease: (any SPUReportIntervalJournal)?

    private let store: any SPUReportIntervalStore
    private let journal: any SPUReportIntervalJournal
    private var record: SPUReportIntervalJournalRecord?
    private var blockedRecovery = false
    private var ownsLease = false

    init(store: any SPUReportIntervalStore, journal: any SPUReportIntervalJournal) {
        self.store = store
        self.journal = journal
    }

    var hasPendingRestore: Bool { record != nil || blockedRecovery }

    /// Recovers a pending interval transaction without ever activating it. The store factory is
    /// called only after a journal record is found under the cross-process lease.
    static func recoverPendingOnly(
        journal proposedJournal: any SPUReportIntervalJournal,
        storeProvider: @MainActor () throws -> any SPUReportIntervalStore
    ) throws {
        if let retainedRecovery {
            try retainedRecovery.recoverPendingRecord()
            retainedRecovery.releaseLease()
            self.retainedRecovery = nil
            return
        }

        let journal = retainedJournalLease ?? proposedJournal
        if retainedJournalLease == nil {
            do { try journal.acquireLease() }
            catch { throw SPUReportIntervalActivationError.leaseUnavailable }
        }

        do {
            guard try journal.load() != nil else {
                journal.releaseLease()
                retainedJournalLease = nil
                return
            }
            let store = try storeProvider()
            let recovery = SPUReportIntervalActivation(store: store, journal: journal)
            recovery.ownsLease = true
            do {
                try recovery.recoverPendingRecord()
                recovery.releaseLease()
                retainedJournalLease = nil
            } catch {
                retainedRecovery = recovery
                throw error
            }
        } catch {
            if retainedRecovery == nil { retainedJournalLease = journal }
            throw error
        }
    }

    func activate() throws {
        guard !ownsLease else { return }
        do {
            try journal.acquireLease()
            ownsLease = true
        } catch {
            throw SPUReportIntervalActivationError.leaseUnavailable
        }

        do {
            try recoverPendingRecord()
            let original = try store.read()
            guard original.value == 0 else {
                throw SPUReportIntervalActivationError.unexpectedOriginalValue(original.value)
            }
            guard supports(original.cfNumberType, value: Self.enabledInterval) else {
                throw SPUReportIntervalActivationError.unsupportedNumberType(original.cfNumberType)
            }

            let nextRecord = SPUReportIntervalJournalRecord(
                identity: store.identity,
                original: original,
                intendedValue: Self.enabledInterval
            )
            // The recovery record must be durable before changing the global registry property.
            try journal.save(nextRecord)
            record = nextRecord
            do {
                try store.write(Self.enabledInterval, preserving: original.cfNumberType)
            } catch {
                do {
                    try store.write(original.value, preserving: original.cfNumberType)
                    try journal.remove()
                    record = nil
                    releaseLease()
                } catch {
                    throw SPUReportIntervalActivationError.restoreFailed(String(describing: error))
                }
                throw error
            }
        } catch {
            if record == nil && !blockedRecovery { releaseLease() }
            throw error
        }
    }

    /// Explicitly writes the original value even when IOKit read-back still reports zero.
    /// On failure the journal and exclusive lease remain held for a later retry.
    func restore() throws {
        guard !blockedRecovery else {
            throw SPUReportIntervalActivationError.restoreFailed("the retained recovery record is malformed; refusing to replay it")
        }
        guard let record else {
            releaseLease()
            return
        }
        do {
            try store.write(record.original.value, preserving: record.original.cfNumberType)
            try journal.remove()
            self.record = nil
            releaseLease()
        } catch {
            throw SPUReportIntervalActivationError.restoreFailed(String(describing: error))
        }
    }

    private func recoverPendingRecord() throws {
        guard let pending = try journal.load() else { return }
        guard !pending.identity.bootIdentity.isEmpty,
              pending.identity.driverRegistryID != 0,
              pending.original.value == 0,
              pending.intendedValue == Self.enabledInterval,
              supports(pending.original.cfNumberType, value: pending.intendedValue) else {
            blockedRecovery = true
            throw SPUReportIntervalActivationError.journal("recovery record does not match the fixed interval operation")
        }
        if pending.identity == store.identity {
            do {
                try store.write(pending.original.value, preserving: pending.original.cfNumberType)
            } catch {
                record = pending
                throw SPUReportIntervalActivationError.restoreFailed(String(describing: error))
            }
        }
        // A different boot or driver is not safe to replay against; discard without writing.
        try journal.remove()
    }

    private func releaseLease() {
        guard ownsLease else { return }
        journal.releaseLease()
        ownsLease = false
    }

    private func supports(_ type: Int, value: Int64) -> Bool {
        guard let numberType = CFNumberType(rawValue: type) else { return false }
        return switch numberType {
        case .sInt8Type: value >= Int64(Int8.min) && value <= Int64(Int8.max)
        case .sInt16Type: value >= Int64(Int16.min) && value <= Int64(Int16.max)
        case .sInt32Type: value >= Int64(Int32.min) && value <= Int64(Int32.max)
        case .sInt64Type: true
        default: false
        }
    }
}

/// Fixed-property adapter for the uniquely identified AppleSPUHIDDriver.
final class IOKitSPUReportIntervalStore: SPUReportIntervalStore {
    let identity: SPUReportIntervalIdentity

    init(identity: SPUReportIntervalIdentity) { self.identity = identity }

    func read() throws -> SPUReportIntervalValue {
        let driver = try openDriver()
        defer { IOObjectRelease(driver) }
        guard let number = IORegistryEntryCreateCFProperty(
            driver, "ReportInterval" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue(), CFGetTypeID(number) == CFNumberGetTypeID() else {
            throw SPUReportIntervalActivationError.missingOrUnreadableProperty
        }
        let cfNumber = unsafeDowncast(number, to: CFNumber.self)
        let type = CFNumberGetType(cfNumber)
        let rawType = type.rawValue
        let value: Int64
        switch type {
        case .sInt8Type:
            var v: Int8 = 0
            guard CFNumberGetValue(cfNumber, type, &v) else { throw SPUReportIntervalActivationError.missingOrUnreadableProperty }
            value = Int64(v)
        case .sInt16Type:
            var v: Int16 = 0
            guard CFNumberGetValue(cfNumber, type, &v) else { throw SPUReportIntervalActivationError.missingOrUnreadableProperty }
            value = Int64(v)
        case .sInt32Type:
            var v: Int32 = 0
            guard CFNumberGetValue(cfNumber, type, &v) else { throw SPUReportIntervalActivationError.missingOrUnreadableProperty }
            value = Int64(v)
        case .sInt64Type:
            var v: Int64 = 0
            guard CFNumberGetValue(cfNumber, type, &v) else { throw SPUReportIntervalActivationError.missingOrUnreadableProperty }
            value = v
        default:
            throw SPUReportIntervalActivationError.unsupportedNumberType(rawType)
        }
        return SPUReportIntervalValue(value: value, cfNumberType: rawType)
    }

    func write(_ value: Int64, preserving numberTypeRawValue: Int) throws {
        let driver = try openDriver()
        defer { IOObjectRelease(driver) }
        guard let type = CFNumberType(rawValue: numberTypeRawValue) else {
            throw SPUReportIntervalActivationError.unsupportedNumberType(numberTypeRawValue)
        }
        let number: CFNumber?
        switch type {
        case .sInt8Type where value >= Int64(Int8.min) && value <= Int64(Int8.max):
            var v = Int8(value); number = CFNumberCreate(kCFAllocatorDefault, type, &v)
        case .sInt16Type where value >= Int64(Int16.min) && value <= Int64(Int16.max):
            var v = Int16(value); number = CFNumberCreate(kCFAllocatorDefault, type, &v)
        case .sInt32Type where value >= Int64(Int32.min) && value <= Int64(Int32.max):
            var v = Int32(value); number = CFNumberCreate(kCFAllocatorDefault, type, &v)
        case .sInt64Type:
            var v = value; number = CFNumberCreate(kCFAllocatorDefault, type, &v)
        default:
            throw SPUReportIntervalActivationError.unsupportedNumberType(numberTypeRawValue)
        }
        guard let number else { throw SPUReportIntervalActivationError.missingOrUnreadableProperty }
        let result = IORegistryEntrySetCFProperty(driver, "ReportInterval" as CFString, number)
        guard result == KERN_SUCCESS else {
            throw SPUReportIntervalActivationError.propertyWrite(Int32(result))
        }
    }

    private func openDriver() throws -> io_service_t {
        guard let matching = IORegistryEntryIDMatching(identity.driverRegistryID as UInt64) else {
            throw SPUReportIntervalActivationError.identityUnavailable
        }
        let driver = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard driver != IO_OBJECT_NULL,
              IOObjectConformsTo(driver, "AppleSPUHIDDriver") != 0,
              registryString(driver, "Product") == "accel",
              registryInteger(driver, "PrimaryUsagePage") == 0xFF00,
              registryInteger(driver, "PrimaryUsage") == 3,
              hasOnlyAccelerometerUsagePair(driver) else {
            if driver != IO_OBJECT_NULL { IOObjectRelease(driver) }
            throw SPUReportIntervalActivationError.identityUnavailable
        }
        return driver
    }

    private func registryString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private func registryInteger(_ entry: io_registry_entry_t, _ key: String) -> Int64? {
        guard let value = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return value.int64Value
    }

    private func hasOnlyAccelerometerUsagePair(_ entry: io_registry_entry_t) -> Bool {
        guard let pairs = IORegistryEntryCreateCFProperty(
            entry, "DeviceUsagePairs" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]], pairs.count == 1,
        let pair = pairs.first,
        (pair["DeviceUsagePage"] as? NSNumber)?.intValue == 0xFF00,
        (pair["DeviceUsage"] as? NSNumber)?.intValue == 3 else { return false }
        return true
    }
}

/// A per-user, fsynced recovery journal and cross-process exclusive lease.
final class FileSPUReportIntervalJournal: SPUReportIntervalJournal {
    private let directory: URL
    private let recordURL: URL
    private let lockURL: URL
    private var lockDescriptor: Int32 = -1

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screen Privacy", isDirectory: true)
        recordURL = self.directory.appendingPathComponent("SPUReportIntervalRecovery.json")
        lockURL = self.directory.appendingPathComponent("SPUReportIntervalRecovery.lock")
    }

    func acquireLease() throws {
        guard lockDescriptor < 0 else { return }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw SPUReportIntervalActivationError.journal(String(describing: error)) }
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw SPUReportIntervalActivationError.leaseUnavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw SPUReportIntervalActivationError.leaseUnavailable
        }
        lockDescriptor = descriptor
    }

    func releaseLease() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        close(lockDescriptor)
        lockDescriptor = -1
    }

    deinit { releaseLease() }

    func load() throws -> SPUReportIntervalJournalRecord? {
        guard FileManager.default.fileExists(atPath: recordURL.path) else { return nil }
        do {
            let descriptor = open(recordURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(), (info.st_mode & 0o077) == 0,
                  info.st_size > 0, info.st_size <= 4_096 else {
                throw SPUReportIntervalActivationError.journal("recovery file ownership or permissions are unsafe")
            }
            var data = Data(count: Int(info.st_size))
            var offset = 0
            while offset < data.count {
                let remaining = data.count - offset
                let amount = data.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), remaining)
                }
                guard amount > 0 else { throw SPUReportIntervalActivationError.journal("recovery record could not be read completely") }
                offset += amount
            }
            return try JSONDecoder().decode(SPUReportIntervalJournalRecord.self, from: data)
        } catch { throw SPUReportIntervalActivationError.journal(String(describing: error)) }
    }

    func save(_ record: SPUReportIntervalJournalRecord) throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(record)
            let temporary = directory.appendingPathComponent(".SPUReportIntervalRecovery.\(UUID().uuidString).tmp")
            let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            var writeError: Error?
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                    if written <= 0 { writeError = POSIXError(.EIO); return }
                    offset += written
                }
            }
            if writeError == nil && fsync(descriptor) != 0 { writeError = POSIXError(.EIO) }
            close(descriptor)
            if let writeError { unlink(temporary.path); throw writeError }
            guard rename(temporary.path, recordURL.path) == 0 else { unlink(temporary.path); throw POSIXError(.EIO) }
            let dir = open(directory.path, O_RDONLY | O_CLOEXEC)
            guard dir >= 0 else { throw POSIXError(.EIO) }
            let syncResult = fsync(dir)
            close(dir)
            guard syncResult == 0 else { throw POSIXError(.EIO) }
        } catch { throw SPUReportIntervalActivationError.journal(String(describing: error)) }
    }

    func remove() throws {
        guard unlink(recordURL.path) == 0 || errno == ENOENT else {
            throw SPUReportIntervalActivationError.journal("could not remove recovery record")
        }
        let descriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SPUReportIntervalActivationError.journal("could not open recovery directory for sync") }
        let syncResult = fsync(descriptor)
        close(descriptor)
        guard syncResult == 0 else { throw SPUReportIntervalActivationError.journal("could not sync recovery directory") }
    }
}

func currentSPUBootIdentity() -> String? {
    var size = 0
    guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}
