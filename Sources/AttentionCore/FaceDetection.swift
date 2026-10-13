import Foundation

/// One face from the detector, before it is reduced to a pose for `AttentionState`.
public struct DetectedFace: Sendable, Equatable {
    public let confidence: Double
    /// Radians.
    public let yaw: Double?
    /// Radians.
    public let pitch: Double?

    public init(confidence: Double, yaw: Double?, pitch: Double?) {
        self.confidence = confidence
        self.yaw = yaw
        self.pitch = pitch
    }
}

/// Combines detection passes so a retry can add evidence but never hide a face.
public enum FaceDetectionMerge {
    public static let minimumPoseConfidence = 0.7

    /// More than one face, or one face confident enough to trust its pose.
    /// Inconclusive frames get a light-assist pass.
    public static func isConclusive(_ faces: [DetectedFace]) -> Bool {
        if faces.count > 1 { return true }
        guard let face = faces.first else { return false }
        return face.confidence >= minimumPoseConfidence
    }

    /// Never lets a later pass hide a face: more faces wins; equal counts prefer
    /// the higher weakest confidence; otherwise keep `current`.
    public static func preferred(_ current: [DetectedFace], _ candidate: [DetectedFace]) -> [DetectedFace] {
        if candidate.count != current.count {
            return candidate.count > current.count ? candidate : current
        }
        return weakestConfidence(candidate) > weakestConfidence(current) ? candidate : current
    }

    /// Poses for `AttentionState`: NaN yaw/pitch when confidence is below
    /// `minimumPoseConfidence` or an angle is missing. Every face is kept so
    /// multiple people still count.
    public static func poses(_ faces: [DetectedFace]) -> [FacePose] {
        faces.map { face in
            guard face.confidence >= minimumPoseConfidence,
                  let yaw = face.yaw, let pitch = face.pitch else {
                return FacePose(yaw: .nan, pitch: .nan)
            }
            return FacePose(yaw: yaw, pitch: pitch)
        }
    }

    private static func weakestConfidence(_ faces: [DetectedFace]) -> Double {
        faces.map(\.confidence).min() ?? 0
    }
}

/// Coarse exposure class of a camera frame, used to explain and assist detection.
public enum LightingCondition: Sendable, Equatable {
    case normal, bright, dark

    /// Inputs are normalized 0...1 luma statistics of the frame. Non-finite
    /// inputs are not evidence of a lighting problem and classify as `.normal`.
    public static func classify(meanLuma: Double, highlightFraction: Double,
                                shadowFraction: Double) -> LightingCondition {
        guard meanLuma.isFinite, highlightFraction.isFinite, shadowFraction.isFinite else { return .normal }
        if highlightFraction > 0.30 || meanLuma > 0.75 { return .bright }
        if meanLuma < 0.15 || shadowFraction > 0.60 { return .dark }
        return .normal
    }
}
