import Foundation

/// Physical measurements have their own units and thresholds. The stationary
/// arming reference is frozen, so slow tilting cannot disappear into adaptation.
public struct PhysicalMotionPolicy: Sendable {
    public private(set) var isCalibrated = false
    public private(set) var tiltDegrees = 0.0
    public private(set) var latest: MotionSensorReading?
    public private(set) var triggerReason: String?
    private var stationary: [MotionSensorReading] = []
    private var reference: (Double, Double, Double)?
    private var accelerationSince: TimeInterval?
    private var tiltSince: TimeInterval?
    private var previousSensitivity: Double?

    public init() {}
    public static func accelerationThreshold(sensitivity: Double) -> Double { 0.20 * pow(0.1, unit(sensitivity)) }
    public static func tiltThreshold(sensitivity: Double) -> Double { 20 * pow(0.25, unit(sensitivity)) }
    public func isReady(at time: TimeInterval) -> Bool { isCalibrated && latest?.isFresh(at: time) == true }
    public mutating func clearCandidates() { accelerationSince = nil; tiltSince = nil; triggerReason = nil }

    /// Called on every delivered sensor sample, including before the countdown.
    /// A source gap invalidates readiness until a new stationary reference exists.
    @discardableResult
    public mutating func receive(_ sample: MotionSensorReading, armed: Bool, sensitivity: Double) -> Bool {
        guard sample.isValid else { return false }
        if let latest, sample.time <= latest.time || sample.reportCount <= latest.reportCount { return false }
        let gap = latest.map { sample.time - $0.time > 0.2 } ?? false
        if gap { reference = nil; isCalibrated = false; stationary = []; clearCandidates() }
        let normalizedSensitivity = Self.unit(sensitivity)
        if previousSensitivity != normalizedSensitivity { clearCandidates(); previousSensitivity = normalizedSensitivity }
        latest = sample
        let vector = (sample.gravityX, sample.gravityY, sample.gravityZ)
        let magnitude = Self.length(vector)
        let plausible = (0.8...1.2).contains(magnitude)
        if !armed || !isCalibrated {
            // Fixed calibration criteria: moving the slider must not redefine stillness.
            if plausible && sample.rmsMovement < 0.015 {
                if let first = stationary.first, Self.angle(vector, (first.gravityX, first.gravityY, first.gravityZ)) > 2 {
                    stationary = []; isCalibrated = false; reference = nil
                }
                stationary.append(sample)
                while stationary.count > 1 && sample.time - stationary[1].time >= 1 { stationary.removeFirst() }
                if let first = stationary.first, sample.time - first.time >= 1 {
                    let n = Double(stationary.count)
                    reference = stationary.reduce((0.0, 0.0, 0.0)) { ($0.0 + $1.gravityX / n, $0.1 + $1.gravityY / n, $0.2 + $1.gravityZ / n) }
                    isCalibrated = true
                }
            } else {
                stationary = []; reference = nil; isCalibrated = false
            }
        }
        tiltDegrees = plausible ? reference.map { Self.angle(vector, $0) } ?? 0 : 0
        guard armed, isCalibrated else { clearCandidates(); return false }
        if sample.rmsMovement >= Self.accelerationThreshold(sensitivity: sensitivity) {
            if accelerationSince == nil { accelerationSince = sample.time }
        } else { accelerationSince = nil }
        if plausible && tiltDegrees >= Self.tiltThreshold(sensitivity: sensitivity) {
            if tiltSince == nil { tiltSince = sample.time }
        } else { tiltSince = nil }
        if let since = accelerationSince, sample.time - since >= 0.35 {
            if triggerReason == nil { triggerReason = "sustained acceleration" }; return true
        }
        if let since = tiltSince, sample.time - since >= 0.5 {
            if triggerReason == nil { triggerReason = "sustained tilt" }; return true
        }
        return false
    }

    private static func unit(_ x: Double) -> Double { min(max(x.isFinite ? x : 0.5, 0), 1) }
    private static func length(_ v: (Double, Double, Double)) -> Double { sqrt(v.0 * v.0 + v.1 * v.1 + v.2 * v.2) }
    private static func angle(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let denominator = length(a) * length(b)
        guard denominator > 0 else { return 0 }
        return acos(min(max((a.0 * b.0 + a.1 * b.1 + a.2 * b.2) / denominator, -1), 1)) * 180 / .pi
    }
}
