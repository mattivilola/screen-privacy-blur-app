import CoreFoundation
import Foundation
import IOKit
import IOKit.hid
import Darwin

/// One raw, validated Apple SPU accelerometer report and its monotonic arrival time.
public struct SPUAccelerometerReport: Equatable, Sendable {
    public let rawReport: Data
    public let captureTime: TimeInterval
    /// Increments for every valid 22-byte report, independent of how often a client polls.
    public let sequence: UInt64

    public var reportCount: UInt64 { sequence }

    public init(rawReport: Data, captureTime: TimeInterval, sequence: UInt64) {
        self.rawReport = rawReport
        self.captureTime = captureTime
        self.sequence = sequence
    }
}

/// A structured result for the read-only physical accelerometer stream.
public enum SPUAccelerometerStatus: Equatable, Sendable {
    case stopped
    case searching
    case noHardware
    case ambiguousHardware(count: Int)
    case unsupportedTopology(String)
    case openFailed(code: Int32)
    case activationFailed(String)
    case waitingForReports
    case noReports
    case active(reportCount: UInt64)

    public var description: String {
        switch self {
        case .stopped: "Motion sensor stopped"
        case .searching: "Checking motion sensor…"
        case .noHardware: "No built-in SPU accelerometer found"
        case let .ambiguousHardware(count): "Found \(count) matching SPU accelerometers"
        case let .unsupportedTopology(reason): "SPU accelerometer topology is unsupported: \(reason)"
        case let .openFailed(code): "SPU accelerometer could not be opened (IOKit \(String(format: "0x%08x", UInt32(bitPattern: code))))"
        case let .activationFailed(reason): "SPU accelerometer activation failed: \(reason)"
        case .waitingForReports: "SPU accelerometer opened; waiting for reports"
        case .noReports: "SPU accelerometer opened but has not reported"
        case let .active(reportCount): "SPU accelerometer active (\(reportCount) reports)"
        }
    }
}

/// Opens only the AppleSPUHIDDevice endpoint with vendor page 0xFF00 / usage 3.
/// By default the stream is read-only; interval activation is an explicit opt-in.
@MainActor
public final class SPUAccelerometerStream {
    nonisolated public static let reportLength = 22
    nonisolated public static let reportBufferLength = 4096
    nonisolated public static let firstReportTimeout: TimeInterval = 2.0
    nonisolated public static let staleReportTimeout: TimeInterval = 1.5

    private enum State {
        case stopped
        case searching
        case failed(SPUAccelerometerStatus)
        case open(startedAt: TimeInterval)
    }

    private var state: State = .stopped
    private var device: IOHIDDevice?
    private var reportBuffer: UnsafeMutablePointer<UInt8>?
    private var callbackContext: SPUReportBuffer?
    private var timeoutTimer: DispatchSourceTimer?
    private let activateReportInterval: Bool
    private var intervalActivation: SPUReportIntervalActivation?

    /// Activation is opt-in because ReportInterval is a global driver property. When enabled,
    /// this stream journals and restores its original value; the default remains read-only.
    public init(activateReportInterval: Bool = false) {
        self.activateReportInterval = activateReportInterval
    }

    /// Restores a pending interval transaction at app launch without opening the HID device or
    /// enabling reports. If no recovery journal exists, this performs no hardware discovery.
    public static func recoverPendingInterval() throws {
        try SPUReportIntervalActivation.recoverPendingOnly(
            journal: FileSPUReportIntervalJournal(),
            storeProvider: {
                guard case let .success(endpoint) = findAccelerometerEndpoint() else {
                    throw SPUReportIntervalActivationError.identityUnavailable
                }
                defer { IOObjectRelease(endpoint.service) }
                guard let bootIdentity = currentSPUBootIdentity() else {
                    throw SPUReportIntervalActivationError.identityUnavailable
                }
                let identity = SPUReportIntervalIdentity(
                    bootIdentity: bootIdentity,
                    driverRegistryID: endpoint.driverRegistryID
                )
                return IOKitSPUReportIntervalStore(identity: identity)
            }
        )
    }

    /// The latest valid report remains available until the stream stops. Storage is bounded to one report.
    public var latestReport: SPUAccelerometerReport? {
        callbackContext?.snapshot().latest
    }

    /// Number of valid raw reports received since the most recent start.
    public var reportCount: UInt64 {
        callbackContext?.snapshot().count ?? 0
    }

    /// Reports become active only after valid 22-byte input reports arrive.
    public var status: SPUAccelerometerStatus {
        switch state {
        case .stopped:
            return .stopped
        case .searching:
            return .searching
        case let .failed(status):
            return status
        case let .open(startedAt):
            let now = ProcessInfo.processInfo.systemUptime
            guard let latest = callbackContext?.snapshot().latest else {
                if now - startedAt >= Self.firstReportTimeout {
                    closeForNoReports()
                    return terminalNoReportStatus
                }
                return .waitingForReports
            }
            guard now >= latest.captureTime,
                  now - latest.captureTime <= Self.staleReportTimeout else {
                closeForNoReports()
                return terminalNoReportStatus
            }
            return .active(reportCount: latest.sequence)
        }
    }

    /// Starts a direct, unprivileged IOHIDDevice stream. No driver properties are changed.
    public func start(onReport: (@MainActor @Sendable (SPUAccelerometerReport) -> Void)? = nil) {
        stop()
        if intervalActivation?.hasPendingRestore == true {
            state = .failed(.activationFailed("a previous interval restore is still pending"))
            return
        }
        intervalActivation = nil
        state = .searching

        switch Self.findAccelerometerEndpoint() {
        case let .failure(status):
            state = .failed(status)
            return
        case let .success(endpoint):
            defer { IOObjectRelease(endpoint.service) }
            if activateReportInterval {
                guard let bootIdentity = currentSPUBootIdentity() else {
                    state = .failed(.activationFailed("boot identity could not be verified"))
                    return
                }
                let identity = SPUReportIntervalIdentity(bootIdentity: bootIdentity, driverRegistryID: endpoint.driverRegistryID)
                let activation = SPUReportIntervalActivation(
                    store: IOKitSPUReportIntervalStore(identity: identity),
                    journal: FileSPUReportIntervalJournal()
                )
                intervalActivation = activation
                do {
                    try activation.activate()
                } catch {
                    state = .failed(.activationFailed(error.localizedDescription))
                    return
                }
            }

            guard let hidDevice = IOHIDDeviceCreate(kCFAllocatorDefault, endpoint.service) else {
                failAfterActivation(.openFailed(code: kIOReturnNoMemory))
                return
            }

            let openResult = IOHIDDeviceOpen(hidDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                failAfterActivation(.openFailed(code: Int32(bitPattern: UInt32(openResult))))
                return
            }

            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferLength)
            buffer.initialize(repeating: 0, count: Self.reportBufferLength)
            let context = SPUReportBuffer(onReport: onReport)

            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                hidDevice,
                buffer,
                Self.reportBufferLength,
                spuAccelerometerReportCallback,
                Unmanaged.passUnretained(context).toOpaque()
            )
            IOHIDDeviceScheduleWithRunLoop(hidDevice, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

            self.device = hidDevice
            self.reportBuffer = buffer
            self.callbackContext = context
            state = .open(startedAt: ProcessInfo.processInfo.systemUptime)
            startTimeoutTimer()
        }
    }

    /// Unregisters the callback and releases the device. The final report is cleared.
    public func stop() {
        closeDevice(clearSnapshot: true)
        if let intervalActivation {
            do {
                try intervalActivation.restore()
                self.intervalActivation = nil
            } catch {
                state = .failed(.activationFailed(error.localizedDescription))
                return
            }
        }
        state = .stopped
    }

    private func closeForNoReports() {
        closeDevice(clearSnapshot: false)
        if let intervalActivation {
            do {
                try intervalActivation.restore()
                self.intervalActivation = nil
            } catch {
                state = .failed(.activationFailed(error.localizedDescription))
                return
            }
        }
        state = .failed(.noReports)
    }

    private var terminalNoReportStatus: SPUAccelerometerStatus {
        if case let .failed(status) = state { return status }
        return .noReports
    }

    private func failAfterActivation(_ status: SPUAccelerometerStatus) {
        guard let intervalActivation else {
            state = .failed(status)
            return
        }
        do {
            try intervalActivation.restore()
            self.intervalActivation = nil
            state = .failed(status)
        } catch {
            state = .failed(.activationFailed(error.localizedDescription))
        }
    }

    private func closeDevice(clearSnapshot: Bool) {
        timeoutTimer?.setEventHandler {}
        timeoutTimer?.cancel()
        timeoutTimer = nil
        if let callbackContext {
            callbackContext.deactivate(clear: clearSnapshot)
        }
        if let device {
            if let reportBuffer {
                IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                    device, reportBuffer, Self.reportBufferLength, nil, nil
                )
            }
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let reportBuffer {
            reportBuffer.deinitialize(count: Self.reportBufferLength)
            reportBuffer.deallocate()
        }
        device = nil
        reportBuffer = nil
        if clearSnapshot { callbackContext = nil }
    }

    private func startTimeoutTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkForTimeout()
            }
        }
        timer.resume()
        timeoutTimer = timer
    }

    private func checkForTimeout() {
        guard case let .open(startedAt) = state else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard let latest = callbackContext?.snapshot().latest else {
            if now - startedAt >= Self.firstReportTimeout { closeForNoReports() }
            return
        }
        if now < latest.captureTime || now - latest.captureTime > Self.staleReportTimeout {
            closeForNoReports()
        }
    }

    private struct AccelerometerEndpoint {
        let service: io_service_t
        let driverRegistryID: UInt64
    }

    private enum EndpointResult {
        case success(AccelerometerEndpoint)
        case failure(SPUAccelerometerStatus)
    }

    /// Finds exactly one HID endpoint and proves it has exactly one matching Apple SPU driver owner.
    private static func findAccelerometerEndpoint() -> EndpointResult {
        guard let matching = IOServiceMatching("AppleSPUHIDDevice") else {
            return .failure(.noHardware)
        }
        var iterator: io_iterator_t = 0
        let matchingResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchingResult == kIOReturnSuccess else {
            return .failure(.unsupportedTopology("IOKit enumeration failed with \(matchingResult)"))
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [io_service_t] = []
        while let service = nextService(iterator) {
            if integerProperty(service, "PrimaryUsagePage") == 0xFF00,
               integerProperty(service, "PrimaryUsage") == 3 {
                candidates.append(service)
            } else {
                IOObjectRelease(service)
            }
        }

        guard !candidates.isEmpty else { return .failure(.noHardware) }
        guard candidates.count == 1 else {
            candidates.forEach { IOObjectRelease($0) }
            return .failure(.ambiguousHardware(count: candidates.count))
        }

        let endpoint = candidates[0]
        let drivers = descendantDrivers(of: endpoint)
        guard drivers.count == 1 else {
            drivers.forEach { IOObjectRelease($0) }
            IOObjectRelease(endpoint)
            return .failure(.unsupportedTopology("expected one owning AppleSPUHIDDriver, found \(drivers.count)"))
        }
        let driver = drivers[0]
        defer { IOObjectRelease(driver) }

        guard integerProperty(driver, "PrimaryUsagePage") == 0xFF00,
              integerProperty(driver, "PrimaryUsage") == 3,
              stringProperty(driver, "Product") == "accel",
              hasOnlyAccelerometerUsagePair(driver) else {
            IOObjectRelease(endpoint)
            return .failure(.unsupportedTopology("the owning AppleSPUHIDDriver is not a dedicated usage-3 accelerometer"))
        }
        var driverRegistryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(driver, &driverRegistryID) == KERN_SUCCESS,
              driverRegistryID != 0 else {
            IOObjectRelease(endpoint)
            return .failure(.unsupportedTopology("the owning AppleSPUHIDDriver has no stable registry identity"))
        }
        return .success(AccelerometerEndpoint(service: endpoint, driverRegistryID: driverRegistryID))
    }

    private static func nextService(_ iterator: io_iterator_t) -> io_service_t? {
        let service = IOIteratorNext(iterator)
        return service == IO_OBJECT_NULL ? nil : service
    }

    private static func descendantDrivers(of service: io_service_t) -> [io_service_t] {
        var result: [io_service_t] = []
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator) == kIOReturnSuccess else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        while let child = nextService(iterator) {
            if IOObjectConformsTo(child, "AppleSPUHIDDriver") != 0 {
                result.append(child)
            } else {
                result.append(contentsOf: descendantDrivers(of: child))
                IOObjectRelease(child)
            }
        }
        return result
    }

    private static func hasOnlyAccelerometerUsagePair(_ driver: io_service_t) -> Bool {
        guard let value = property(driver, "DeviceUsagePairs") as? [[String: Any]], value.count == 1,
              let pair = value.first,
              (pair["DeviceUsagePage"] as? NSNumber)?.intValue == 0xFF00,
              (pair["DeviceUsage"] as? NSNumber)?.intValue == 3 else {
            return false
        }
        return true
    }

    private static func integerProperty(_ entry: io_registry_entry_t, _ name: String) -> Int64? {
        guard let value = property(entry, name) as? NSNumber,
              CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
        return value.int64Value
    }

    private static func stringProperty(_ entry: io_registry_entry_t, _ name: String) -> String? {
        property(entry, name) as? String
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// The HID callback only copies a small known report into a lock-protected latest-value slot.
/// This keeps memory bounded and lets XPC clients poll without pushing at the sensor's rate.
final class SPUReportBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let onReport: (@MainActor @Sendable (SPUAccelerometerReport) -> Void)?
    private let currentUptime: @Sendable () -> TimeInterval
    private let secondsFromMachTimestamp: @Sendable (UInt64) -> TimeInterval
    private var active = true
    private var latest: SPUAccelerometerReport?
    private var count: UInt64 = 0
    private var lastMachTimestamp: UInt64 = 0

    init(
        onReport: (@MainActor @Sendable (SPUAccelerometerReport) -> Void)?,
        currentUptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        secondsFromMachTimestamp: @escaping @Sendable (UInt64) -> TimeInterval = { SPUReportBuffer.monotonicSeconds(from: $0) }
    ) {
        self.onReport = onReport
        self.currentUptime = currentUptime
        self.secondsFromMachTimestamp = secondsFromMachTimestamp
    }

    func accept(_ bytes: UnsafePointer<UInt8>, length: Int, machTimestamp: UInt64) {
        guard length == SPUAccelerometerStream.reportLength else { return }
        let reportData = Data(bytes: bytes, count: length)
        let captureTime = secondsFromMachTimestamp(machTimestamp)
        let now = currentUptime()
        guard captureTime.isFinite, captureTime > 0,
              captureTime <= now,
              now - captureTime <= SPUAccelerometerStream.staleReportTimeout else { return }
        let sample: SPUAccelerometerReport
        lock.lock()
        guard active,
              machTimestamp > lastMachTimestamp,
              latest.map({ captureTime > $0.captureTime }) ?? true else {
            lock.unlock()
            return
        }
        lastMachTimestamp = machTimestamp
        count &+= 1
        sample = SPUAccelerometerReport(rawReport: reportData, captureTime: captureTime, sequence: count)
        latest = sample
        lock.unlock()

        guard let onReport else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { onReport(sample) }
        } else {
            Task { @MainActor [weak self] in
                guard self?.isActive == true else { return }
                onReport(sample)
            }
        }
    }

    func snapshot() -> (latest: SPUAccelerometerReport?, count: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (latest, count)
    }

    func deactivate(clear: Bool) {
        lock.lock()
        active = false
        if clear {
            latest = nil
            count = 0
            lastMachTimestamp = 0
        }
        lock.unlock()
    }

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private static func monotonicSeconds(from timestamp: UInt64) -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return Double(timestamp) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}

private let spuAccelerometerReportCallback: IOHIDReportWithTimeStampCallback = {
    context, result, _, reportType, _, report, reportLength, timestamp in
    guard result == kIOReturnSuccess,
          reportType == kIOHIDReportTypeInput,
          reportLength == SPUAccelerometerStream.reportLength,
          let context else { return }
    Unmanaged<SPUReportBuffer>.fromOpaque(context).takeUnretainedValue()
        .accept(report, length: Int(reportLength), machTimestamp: timestamp)
}
