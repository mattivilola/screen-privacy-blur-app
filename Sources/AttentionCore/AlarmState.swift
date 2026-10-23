import Foundation

/// Alarm arming is separate from attention: returning faces never silence an armed alarm.
public struct AlarmState: Sendable {
    public enum Phase: Equatable, Sendable {
        case off, waiting, countdown(until: TimeInterval), armed, alarming
    }
    public private(set) var phase: Phase = .off
    public var sensitivity: Double = 0.5
    public var countdown: TimeInterval = 10
    public private(set) var physicalMotion = PhysicalMotionPolicy()
    private var wasPhysicalPrimary = false
    private var decisionTime = -Double.infinity
    private var hasSeenWatching = false
    private var stillSince: TimeInterval?
    private var evidence: [String: (start: TimeInterval, last: TimeInterval)] = [:]

    public init() {}
    public var isLatched: Bool { phase == .armed || phase == .alarming }
    public var threshold: Double { 0.20 - Self.unit(sensitivity) * 0.17 }
    public var sensorAccelerationThreshold: Double { PhysicalMotionPolicy.accelerationThreshold(sensitivity: sensitivity) }
    public var sensorTiltThreshold: Double { PhysicalMotionPolicy.tiltThreshold(sensitivity: sensitivity) }
    public func usesPhysicalPrimary(at time: TimeInterval) -> Bool { physicalMotion.isReady(at: max(time, decisionTime)) }
    public mutating func receiveSensor(_ sample: MotionSensorReading) {
        guard sample.isValid else { return }
        let triggered = physicalMotion.receive(sample, armed: isLatched, sensitivity: sensitivity)
        synchronizePrimary(at: sample.time)
        if phase == .armed && triggered { phase = .alarming; evidence = [:] }
    }
    private mutating func synchronizePrimary(at time: TimeInterval) {
        decisionTime = max(decisionTime, time)
        let primary = usesPhysicalPrimary(at: decisionTime)
        if primary != wasPhysicalPrimary { evidence = [:]; physicalMotion.clearCandidates(); wasPhysicalPrimary = primary }
    }
    public mutating func enable() { physicalMotion = PhysicalMotionPolicy(); wasPhysicalPrimary = false; decisionTime = -Double.infinity; phase = .waiting; evidence = [:]; hasSeenWatching = false; stillSince = nil }
    public mutating func disable() { physicalMotion = PhysicalMotionPolicy(); wasPhysicalPrimary = false; decisionTime = -Double.infinity; phase = .off; evidence = [:]; hasSeenWatching = false; stillSince = nil }
    public mutating func interrupt() {
        evidence = [:]
        // Camera/attention interruptions do not discard independent, fresh sensor evidence.
        if !isLatched { physicalMotion = PhysicalMotionPolicy(); wasPhysicalPrimary = false; decisionTime = -Double.infinity }
        stillSince = nil
        if !isLatched { hasSeenWatching = false }
        if case .countdown = phase { phase = .waiting }
    }
    public mutating func observe(watching: Bool, cameraMotion: Double? = nil, physicalOnly: Bool = false, at time: TimeInterval) {
        guard time.isFinite else { interrupt(); return }
        synchronizePrimary(at: time)
        let hasFreshPhysical = physicalMotion.latest?.isFresh(at: max(time, decisionTime)) == true
        if watching { hasSeenWatching = true }
        if let cameraMotion, cameraMotion.isFinite, cameraMotion < threshold {
            if stillSince == nil { stillSince = time }
        } else if cameraMotion != nil { stillSince = nil }
        let settled = physicalOnly || hasFreshPhysical ? physicalMotion.isCalibrated
            : cameraMotion == nil || stillSince.map { time - $0 >= 1 } == true
        switch phase {
        case .waiting where !watching && hasSeenWatching:
            phase = .countdown(until: time + max(3, countdown.isFinite ? countdown : 10))
        case .countdown where watching:
            phase = .waiting
        case let .countdown(until) where time >= until && settled:
            phase = .armed
            evidence = [:]
        default: break
        }
    }
    public mutating func trigger() { if phase == .armed { phase = .alarming; evidence = [:] } }
    public mutating func motion(_ score: Double, source: String, at time: TimeInterval) {
        guard phase == .armed, score.isFinite, time.isFinite else { return }
        synchronizePrimary(at: time)
        if source == "camera" && usesPhysicalPrimary(at: time) { evidence[source] = nil; return }
        guard score >= threshold else { evidence[source] = nil; return }
        if let previous = evidence[source], time >= previous.last, time - previous.last <= 0.8 {
            if time - previous.start >= 0.24 { phase = .alarming; evidence = [:] }
            else { evidence[source] = (previous.start, time) }
        } else { evidence[source] = (time, time) }
    }
    private static func unit(_ x: Double) -> Double { min(max(x.isFinite ? x : 0.5, 0), 1) }
}

/// Small luma grids only. Global exposure changes are subtracted before comparing frames.
public struct CameraMotionEvidence: Sendable {
    private var previous: [Double] = []
    public init() {}
    public mutating func reset() { previous = [] }
    public mutating func score(_ samples: [Double]) -> Double? {
        defer { previous = samples }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite), samples.count == previous.count, previous.allSatisfy(\.isFinite) else { return nil }
        let exposure = zip(samples, previous).reduce(0.0) { $0 + $1.0 - $1.1 } / Double(samples.count)
        return zip(samples, previous).reduce(0.0) { $0 + abs(($1.0 - $1.1) - exposure) } / Double(samples.count)
    }
}
