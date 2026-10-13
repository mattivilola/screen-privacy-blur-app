import Foundation

/// Head-angle and timing limits derived from a tolerance setting.
///
/// Shared by `AttentionState` and the live menu feedback so both always agree.
public struct AttentionLimits: Sendable, Equatable {
    /// Fraction of the limits a returning face must stay within before the cover lifts.
    public static let recoveryFraction = 0.8

    public let yawDegrees: Double
    public let pitchDegrees: Double
    public let awayDelay: TimeInterval

    /// Tolerance is clamped to 0...1; a non-finite value falls back to the 0.5 default.
    public init(tolerance: Double) {
        let t = Self.normalizedTolerance(tolerance)
        yawDegrees = 12 + (23 * t)
        pitchDegrees = 12 + (18 * t)
        awayDelay = 0.35 + (0.90 * t)
    }

    /// How far a pose is toward the limit: 1 is exactly at the limit, the worse axis wins.
    /// Returns nil when the pose is not finite.
    public func ratio(for face: FacePose) -> Double? {
        guard face.yaw.isFinite, face.pitch.isFinite else { return nil }
        let radiansToDegrees = 180 / Double.pi
        return max(abs(face.yaw * radiansToDegrees) / yawDegrees,
                   abs(face.pitch * radiansToDegrees) / pitchDegrees)
    }

    static let defaultTolerance = 0.5

    static func normalizedTolerance(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTolerance }
        return min(max(value, 0), 1)
    }
}
