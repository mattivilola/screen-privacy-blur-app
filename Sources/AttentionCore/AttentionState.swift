import Foundation

/// A head pose measured in radians relative to the camera.
public struct FacePose: Sendable {
    public let yaw: Double
    public let pitch: Double

    public init(yaw: Double, pitch: Double) {
        self.yaw = yaw
        self.pitch = pitch
    }
}

/// Conservatively decides whether a privacy cover should be shown.
///
/// The state begins covered and only uncovers after one valid face has looked
/// at the screen continuously for the recovery interval.
public struct AttentionState: Sendable {
    private static let defaultTolerance = 0.5
    private static let recoveryDelay: TimeInterval = 0.35
    private static let maximumEvidenceGap: TimeInterval = 1.0
    private static let timingEpsilon: TimeInterval = 0.000_001

    private var lastTime: TimeInterval?
    private var lookingSince: TimeInterval?
    private var awaySince: TimeInterval?

    public var tolerance: Double {
        didSet {
            let normalized = Self.normalizedTolerance(tolerance)
            if tolerance != normalized {
                tolerance = normalized
            }
            if normalized != oldValue {
                resetTemporalEvidence()
            }
        }
    }

    public private(set) var isCovered: Bool

    public init(tolerance: Double = 0.5) {
        self.tolerance = Self.normalizedTolerance(tolerance)
        self.isCovered = true
    }

    /// Incorporates one camera observation and returns whether the cover is shown.
    @discardableResult
    public mutating func update(faces: [FacePose], at time: TimeInterval) -> Bool {
        guard time.isFinite else {
            return unavailable()
        }

        if let lastTime {
            guard time >= lastTime else {
                isCovered = true
                resetEvidence()
                return isCovered
            }

            guard time - lastTime <= Self.maximumEvidenceGap else {
                isCovered = true
                resetEvidence()
                self.lastTime = time
                return isCovered
            }
        }
        lastTime = time

        // More than one person is an immediate privacy risk. An invalid pose is
        // treated the same way: it is not evidence that the display is safe.
        guard faces.count == 1, let face = faces.first else {
            if faces.count > 1 {
                return coverImmediately()
            }
            return handleAway(at: time)
        }

        guard Self.isValid(face) else {
            return coverImmediately()
        }

        if isCovered {
            guard Self.isLooking(face, tolerance: tolerance, returning: true) else {
                lookingSince = nil
                awaySince = nil
                return isCovered
            }

            awaySince = nil
            if let lookingSince {
                if time - lookingSince >= Self.recoveryDelay - Self.timingEpsilon {
                    isCovered = false
                    self.lookingSince = nil
                }
            } else {
                lookingSince = time
            }
            return isCovered
        }

        guard Self.isLooking(face, tolerance: tolerance, returning: false) else {
            return handleAway(at: time)
        }

        lookingSince = nil
        awaySince = nil
        return isCovered
    }

    /// Marks camera attention as unavailable and immediately restores privacy.
    @discardableResult
    public mutating func unavailable() -> Bool {
        isCovered = true
        resetEvidence()
        return isCovered
    }

    private mutating func handleAway(at time: TimeInterval) -> Bool {
        lookingSince = nil
        guard !isCovered else { return isCovered }

        if let awaySince {
            if time - awaySince >= Self.awayDelay(for: tolerance) - Self.timingEpsilon {
                isCovered = true
                self.awaySince = nil
            }
        } else {
            awaySince = time
        }
        return isCovered
    }

    private mutating func coverImmediately() -> Bool {
        isCovered = true
        resetEvidence()
        return isCovered
    }

    private mutating func resetEvidence() {
        resetTemporalEvidence()
        lastTime = nil
    }

    private mutating func resetTemporalEvidence() {
        lookingSince = nil
        awaySince = nil
    }

    private static func normalizedTolerance(_ value: Double) -> Double {
        guard value.isFinite else { return defaultTolerance }
        return min(max(value, 0), 1)
    }

    private static func isValid(_ face: FacePose) -> Bool {
        face.yaw.isFinite && face.pitch.isFinite
    }

    private static func isLooking(_ face: FacePose, tolerance: Double, returning: Bool) -> Bool {
        let yawLimit = 12 + (23 * tolerance)
        let pitchLimit = 12 + (18 * tolerance)
        let hysteresis = returning ? 0.8 : 1.0
        let radiansToDegrees = 180 / Double.pi

        return abs(face.yaw * radiansToDegrees) <= yawLimit * hysteresis
            && abs(face.pitch * radiansToDegrees) <= pitchLimit * hysteresis
    }

    private static func awayDelay(for tolerance: Double) -> TimeInterval {
        0.35 + (0.90 * tolerance)
    }
}
