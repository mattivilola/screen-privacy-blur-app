import Foundation

public struct MotionSensorReading: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double
    /// Instantaneous gravity-filtered acceleration after a small noise floor. The alarm uses RMS below.
    public let movement: Double
    /// Native-rate, time-weighted RMS of the unclamped dynamic acceleration.
    public let rmsMovement: Double
    public let gravityX: Double
    public let gravityY: Double
    public let gravityZ: Double
    public let time: TimeInterval
    /// Counts raw valid reports before UI delivery is throttled.
    public let reportCount: UInt64

    public init(x: Double, y: Double, z: Double, movement: Double, time: TimeInterval, reportCount: UInt64, rmsMovement: Double? = nil, gravityX: Double? = nil, gravityY: Double? = nil, gravityZ: Double? = nil) {
        self.x = x; self.y = y; self.z = z; self.movement = movement
        self.time = time; self.reportCount = reportCount
        self.rmsMovement = rmsMovement ?? movement
        self.gravityX = gravityX ?? x; self.gravityY = gravityY ?? y; self.gravityZ = gravityZ ?? z
    }
    public func isFresh(at now: TimeInterval) -> Bool {
        now.isFinite && time.isFinite && now >= time && now - time <= 1.5
    }
    public var magnitude: Double { sqrt(x * x + y * y + z * z) }
    public var isValid: Bool {
        [x, y, z, movement, rmsMovement, gravityX, gravityY, gravityZ, time].allSatisfy(\.isFinite) && (0...1).contains(movement) && rmsMovement >= 0
    }
}

/// Decodes only the known 22-byte Apple SPU accelerometer report. Unknown layouts
/// are ignored, so an opened HID interface alone never establishes a working sensor.
public enum MotionSensorReport {
    public static func axes(_ bytes: [UInt8]) -> (x: Double, y: Double, z: Double)? {
        guard bytes.count == 22 else { return nil }
        func value(_ offset: Int) -> Double {
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            return Double(Int32(bitPattern: bits)) / 65_536
        }
        return (value(6), value(10), value(14))
    }
}

/// Shared by the alarm and the diagnostic, so the displayed movement is exactly
/// what physical-sensor alarm detection receives. The first sample establishes gravity.
public struct MotionSensorFilter: Sendable {
    private var gravity: (x: Double, y: Double, z: Double)?
    private var lastTime: TimeInterval?
    private var reportCount: UInt64 = 0
    private var energy: [(start: TimeInterval, end: TimeInterval, square: Double)] = []
    private var energyHead = 0
    private var energySum = 0.0
    private var energyDuration = 0.0
    public init() {}
    public mutating func sample(x: Double, y: Double, z: Double, at time: TimeInterval) -> MotionSensorReading? {
        guard [x, y, z, time].allSatisfy(\.isFinite) else { return nil }
        let gap = lastTime.map { time - $0 }
        if gap.map({ $0 <= 0 || $0 > 0.2 }) == true {
            gravity = nil; energy = []; energyHead = 0; energySum = 0; energyDuration = 0
        }
        var magnitude = 0.0
        if let gravity {
            let elapsed = min(max(gap ?? 0.001, 0.001), 0.25)
            let alpha = elapsed / (0.65 + elapsed)
            let updated = (x: gravity.x + alpha * (x - gravity.x),
                           y: gravity.y + alpha * (y - gravity.y),
                           z: gravity.z + alpha * (z - gravity.z))
            self.gravity = updated
            magnitude = sqrt(pow(x - updated.x, 2) + pow(y - updated.y, 2) + pow(z - updated.z, 2))
        } else { gravity = (x, y, z) }
        let elapsed = min(max(gap ?? 0, 0), 0.2)
        if elapsed > 0 {
            energy.append((time - elapsed, time, magnitude * magnitude))
            energySum += magnitude * magnitude * elapsed
            energyDuration += elapsed
        }
        let cutoff = time - 0.25
        while energyHead < energy.count && (energy[energyHead].end <= cutoff || energy.count - energyHead > 512) {
            let old = energy[energyHead]
            let duration = old.end - old.start
            energySum -= old.square * duration; energyDuration -= duration
            energyHead += 1
        }
        if energyHead < energy.count, energy[energyHead].start < cutoff {
            let removed = cutoff - energy[energyHead].start
            energySum -= energy[energyHead].square * removed; energyDuration -= removed
            energy[energyHead].start = cutoff
        }
        if energyHead >= 256 { energy.removeFirst(energyHead); energyHead = 0 }
        let rms = energyDuration > 0 ? sqrt(max(0, energySum / energyDuration)) : 0
        lastTime = time
        reportCount &+= 1
        return MotionSensorReading(x: x, y: y, z: z, movement: min(max(magnitude - 0.008, 0), 1),
                                   time: time, reportCount: reportCount, rmsMovement: rms,
                                   gravityX: gravity!.x, gravityY: gravity!.y, gravityZ: gravity!.z)
    }
}

/// A silent simulation of the actual alarm policy, fed exclusively by physical
/// readings. It never sends effects to the app's real alarm/audio controller.
public struct MotionSensorDiagnostic: Sendable {
    public private(set) var samples: [MotionSensorReading] = []
    public private(set) var peak = 0.0
    public private(set) var observedReports: UInt64 = 0
    private var firstReport: UInt64?
    private var previous: MotionSensorReading?
    private var policy = AlarmState()
    public var sensitivity: Double { policy.sensitivity }
    public var threshold: Double { policy.sensorAccelerationThreshold }
    public var tiltThreshold: Double { policy.sensorTiltThreshold }
    public var tiltDegrees: Double { policy.physicalMotion.tiltDegrees }
    public var isCalibrated: Bool { policy.physicalMotion.isCalibrated }
    public var triggerReason: String? { policy.physicalMotion.triggerReason }
    public var phase: AlarmState.Phase { policy.phase }
    public var latest: MotionSensorReading? { samples.last }
    public var detectedMovement: Bool { policy.phase == .alarming }

    public init(sensitivity: Double) { policy.sensitivity = sensitivity; policy.countdown = 3 }
    public mutating func reset(sensitivity: Double) { self = Self(sensitivity: sensitivity) }
    public func isFresh(at time: TimeInterval) -> Bool {
        latest?.isFresh(at: time) ?? false
    }
    /// Actual HID report rate, rather than the slower UI refresh rate.
    public var reportRate: Double? {
        guard let latest, let anchor = samples.first(where: { latest.time - $0.time <= 1 }),
              latest.time - anchor.time >= 0.2, latest.reportCount >= anchor.reportCount else { return nil }
        return Double(latest.reportCount - anchor.reportCount) / (latest.time - anchor.time)
    }
    public mutating func receive(_ sample: MotionSensorReading) {
        guard sample.isValid else { return }
        if let previous, sample.time <= previous.time || sample.reportCount <= previous.reportCount { return }
        let gap = previous.map { sample.time - $0.time > 1.5 } ?? true
        if gap {
            // Lost evidence cannot complete calibration or a movement test after reconnecting.
            policy.disable(); policy.enable()
            policy.observe(watching: true, at: sample.time)
            samples = []; peak = 0; firstReport = sample.reportCount
        }
        policy.receiveSensor(sample)
        policy.observe(watching: false, cameraMotion: nil, physicalOnly: true, at: sample.time)
        previous = sample
        peak = max(peak, sample.rmsMovement)
        observedReports = sample.reportCount - (firstReport ?? sample.reportCount) + 1
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > 6 }
        if samples.count > 160 { samples.removeFirst(samples.count - 160) }
    }
}
