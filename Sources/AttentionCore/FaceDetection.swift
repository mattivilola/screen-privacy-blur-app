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

    /// More than one face, or one face with a confident, finite pose.
    /// Inconclusive frames get a light-assist pass.
    public static func isConclusive(_ faces: [DetectedFace]) -> Bool {
        if faces.count > 1 { return true }
        guard let face = faces.first else { return false }
        return hasUsablePose(face)
    }

    /// Never lets a later pass hide a face: more faces wins; equal counts prefer
    /// a usable pose, then the higher weakest confidence; otherwise keep `current`.
    public static func preferred(_ current: [DetectedFace], _ candidate: [DetectedFace]) -> [DetectedFace] {
        if candidate.count != current.count {
            return candidate.count > current.count ? candidate : current
        }
        // A confident rectangle with no pose cannot uncover the screen. Prefer
        // a usable pose from the retry even if its rectangle confidence is lower.
        if current.count == 1, let old = current.first, let new = candidate.first,
           hasUsablePose(old) != hasUsablePose(new) {
            return hasUsablePose(new) ? candidate : current
        }
        return weakestConfidence(candidate) > weakestConfidence(current) ? candidate : current
    }

    /// Poses for `AttentionState`: NaN yaw/pitch when confidence is below
    /// `minimumPoseConfidence` or an angle is missing. Every face is kept so
    /// multiple people still count.
    public static func poses(_ faces: [DetectedFace]) -> [FacePose] {
        faces.map { face in
            guard hasUsablePose(face),
                  let yaw = face.yaw, let pitch = face.pitch else {
                return FacePose(yaw: .nan, pitch: .nan)
            }
            return FacePose(yaw: yaw, pitch: pitch)
        }
    }

    private static func weakestConfidence(_ faces: [DetectedFace]) -> Double {
        faces.map(\.confidence).min() ?? 0
    }

    private static func hasUsablePose(_ face: DetectedFace) -> Bool {
        guard face.confidence.isFinite, face.confidence >= minimumPoseConfidence,
              let yaw = face.yaw, let pitch = face.pitch else { return false }
        return yaw.isFinite && pitch.isFinite
    }
}

/// Automatic, bounded software exposure settings. The center is a metering
/// region, not an assumption that a face is present. These values never count
/// as attention evidence; adjusted images must still pass face/pose detection.
public struct LightAssistAdjustment: Sendable, Equatable {
    public let shadowGamma: Double
    public let highlightEV: Double

    public init(centerMeanLuma: Double, highlightFraction: Double) {
        let center = centerMeanLuma.isFinite ? min(1, max(0, centerMeanLuma)) : 0.4
        let highlights = highlightFraction.isFinite ? min(1, max(0, highlightFraction)) : 0
        // Darker centers need a stronger shadow lift. Near-normal centers get
        // a gentle correction; bright frames also get a stronger darkening retry.
        shadowGamma = min(0.85, max(0.4, 0.4 + center * 0.75))
        highlightEV = -min(1.5, max(0.4, highlights * 1.5 + max(0, center - 0.5)))
    }
}

/// Coarse exposure class of a camera frame, used to explain and assist detection.
public enum LightingCondition: Sendable, Equatable {
    case normal, bright, dark, backlit

    /// Inputs are normalized 0...1 luma statistics of the frame. Non-finite
    /// inputs are not evidence of a lighting problem and classify as `.normal`.
    public static func classify(meanLuma: Double, highlightFraction: Double,
                                shadowFraction: Double, centerMeanLuma: Double? = nil) -> LightingCondition {
        guard meanLuma.isFinite, highlightFraction.isFinite, shadowFraction.isFinite else { return .normal }
        // A shaded viewer against sky can have a normally exposed frame overall.
        // This is a lighting hint, never evidence of a person or a covered lens.
        if let center = centerMeanLuma, center.isFinite,
           center < 0.40, meanLuma - center > 0.18, highlightFraction > 0.08 {
            return .backlit
        }
        if highlightFraction > 0.30 || meanLuma > 0.75 { return .bright }
        if meanLuma < 0.15 || shadowFraction > 0.60 { return .dark }
        return .normal
    }
}
