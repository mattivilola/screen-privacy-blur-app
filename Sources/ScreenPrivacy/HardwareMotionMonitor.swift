import CoreFoundation
import Foundation
import IOKit.hid

/// Reads the Apple Silicon SPU accelerometer when it is available to a normal
/// user process. This HID interface is undocumented and may be unavailable on
/// other Macs or macOS releases; callers should keep camera detection active as
/// the fallback.
@MainActor
final class HardwareMotionMonitor {
    private(set) var status = "Motion sensor has not been checked"

    private var manager: IOHIDManager?
    private var reportContext: MotionReportContext?
    private var generation = UUID()
    private var monitoringRequested = false
    private var lastMotionReportAt: TimeInterval?

    var statusText: String {
        guard status == "Motion sensor active" else { return status }
        guard monitoringRequested else { return "Motion sensor stopped" }
        guard let lastMotionReportAt else { return "Motion sensor waiting for reports; using camera" }
        guard ProcessInfo.processInfo.systemUptime - lastMotionReportAt <= 1.5 else {
            return "Motion sensor stopped reporting; using camera"
        }
        return status
    }

    /// True only while reports have been arriving recently, not just because
    /// the HID manager opened successfully.
    var isMonitoring: Bool {
        guard monitoringRequested, let lastMotionReportAt else { return false }
        return ProcessInfo.processInfo.systemUptime - lastMotionReportAt <= 1.5
    }

    /// Starts monitoring the built-in accelerometer. The score is dynamic
    /// acceleration in g, clamped to 0...1, with a small sensor-noise floor
    /// removed. It is suitable for thresholds around 0.03...0.20.
    func start(onMotion: @escaping @MainActor @Sendable (Double) -> Void) {
        stop()
        let run = UUID()
        generation = run
        lastMotionReportAt = nil
        status = "Checking motion sensor…"

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching = [
            kIOHIDDeviceUsagePageKey as String: NSNumber(value: 0xFF00),
            kIOHIDDeviceUsageKey as String: NSNumber(value: 3)
        ] as CFDictionary
        IOHIDManagerSetDeviceMatching(manager, matching)

        let callback: @MainActor @Sendable (Double) -> Void = { [weak self] score in
            guard let self, self.generation == run else { return }
            self.lastMotionReportAt = ProcessInfo.processInfo.systemUptime
            onMotion(score)
        }
        let context = MotionReportContext(deliver: callback)
        reportContext = context

        // Ordinary read access only. The interface is known to require elevated
        // privileges on some macOS/hardware combinations, which this app never
        // requests or attempts to work around.
        IOHIDManagerRegisterInputReportCallback(
            manager,
            hardwareMotionReportCallback,
            Unmanaged.passUnretained(context).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchingDeviceCount = IOHIDManagerCopyDevices(manager).map(CFSetGetCount) ?? 0

        guard matchingDeviceCount > 0 else {
            status = "No built-in motion sensor found; using camera"
            close(manager)
            reportContext = nil
            return
        }
        guard openResult == kIOReturnSuccess else {
            status = "Motion sensor is present but inaccessible; using camera"
            close(manager)
            reportContext = nil
            return
        }

        context.isActive = true
        self.manager = manager
        monitoringRequested = true
        status = "Motion sensor active"
    }

    /// Stops reports and releases the HID manager while retaining the last
    /// availability status for the menu or other UI to display.
    func stop() {
        generation = UUID()
        monitoringRequested = false
        lastMotionReportAt = nil
        reportContext?.isActive = false
        if let manager { close(manager) }
        manager = nil
        reportContext = nil
    }

    private func close(_ manager: IOHIDManager) {
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }
}

/// Report parsing and filtering remain outside the app controller. The HID
/// manager is scheduled on the main run loop, so its callback and this state are
/// serialized there; actor delivery is hopped explicitly through `Task`.
private final class MotionReportContext: @unchecked Sendable {
    private let deliver: @MainActor @Sendable (Double) -> Void
    private var gravity: (x: Double, y: Double, z: Double)?
    private var lastDelivery = 0.0
    var isActive = false

    init(deliver: @escaping @MainActor @Sendable (Double) -> Void) {
        self.deliver = deliver
    }

    func consume(x: Int32, y: Int32, z: Int32) {
        let sample = (Double(x) / 65_536, Double(y) / 65_536, Double(z) / 65_536)
        let now = ProcessInfo.processInfo.systemUptime
        let dynamicMagnitude: Double
        if let gravity {
            let elapsed = min(max(now - lastSampleTime, 0.001), 0.25)
            let alpha = elapsed / (0.65 + elapsed)
            let updated = (
                x: gravity.x + alpha * (sample.0 - gravity.x),
                y: gravity.y + alpha * (sample.1 - gravity.y),
                z: gravity.z + alpha * (sample.2 - gravity.z)
            )
            self.gravity = updated
            let dx = sample.0 - updated.x
            let dy = sample.1 - updated.y
            let dz = sample.2 - updated.z
            dynamicMagnitude = sqrt(dx * dx + dy * dy + dz * dz)
        } else {
            gravity = (sample.0, sample.1, sample.2)
            dynamicMagnitude = 0
        }
        lastSampleTime = now

        guard isActive, now - lastDelivery >= 0.05 else { return }
        lastDelivery = now
        let score = min(max(dynamicMagnitude - 0.008, 0), 1)
        Task { @MainActor [deliver] in deliver(score) }
    }

    private var lastSampleTime = 0.0
}

/// AppleSPUHIDDevice accelerometer reports are 22 bytes. Axis samples are
/// signed little-endian 32-bit values at byte offsets 6, 10 and 14, in g/65536.
private let hardwareMotionReportCallback: IOHIDReportCallback = {
    context, result, _, reportType, _, report, reportLength in
    guard result == kIOReturnSuccess,
          reportType == kIOHIDReportTypeInput,
          reportLength == 22,
          let context else { return }

    let bytes = UnsafeBufferPointer(start: report, count: Int(reportLength))
    func int32LE(at offset: Int) -> Int32 {
        let bits = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Int32(bitPattern: bits)
    }

    let receiver = Unmanaged<MotionReportContext>.fromOpaque(context).takeUnretainedValue()
    receiver.consume(x: int32LE(at: 6), y: int32LE(at: 10), z: int32LE(at: 14))
}
