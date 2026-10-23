import Foundation

/// Camera dropouts, obstruction and a closed lid are possible tampering, not proof of theft.
public struct AlarmTamperEvidence: Sendable {
    private var since: TimeInterval?
    private var previous: TimeInterval?
    public init() {}
    public mutating func reset() { since = nil; previous = nil }
    public mutating func update(armed: Bool, lidClosed: Bool, cameraAvailable: Bool,
                                obscured: Bool, at time: TimeInterval) -> Bool {
        guard armed, time.isFinite, lidClosed || !cameraAvailable || obscured else { reset(); return false }
        if let previous, time < previous || time - previous > 1 { since = nil }
        previous = time
        if since == nil { since = time }
        return time - (since ?? time) >= 2
    }
}
