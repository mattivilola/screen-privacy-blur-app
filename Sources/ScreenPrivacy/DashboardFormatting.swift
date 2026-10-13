import AttentionCore
import Foundation
import OverlayUI
import SnapshotCore

/// Pure text and tone decisions for the menu dashboard.
enum DashboardFormatting {
    /// Camera frames older than this no longer describe what the user is doing.
    private static let staleAnalysisAge: TimeInterval = 1.5

    static func toleranceReading(_ tolerance: Double) -> SettingReading {
        let limits = AttentionLimits(tolerance: tolerance)
        let tier: (name: String, tone: DashboardTone) = switch tolerance {
        case ..<0.34: ("Strict", .good)
        case ..<0.67: ("Balanced", .balanced)
        default: ("Relaxed", .caution)
        }
        return SettingReading(
            valueText: "\(Int((tolerance * 100).rounded()))",
            tierName: tier.name,
            tone: tier.tone,
            detail: "Turn ±\(degrees(limits.yawDegrees))° · tilt ±\(degrees(limits.pitchDegrees))° · covers after \(String(format: "%.1f", limits.awayDelay)) s")
    }

    static func blurReading(_ strength: Double) -> SettingReading {
        let radius = SnapshotDisplay.blurRadiusPoints(forStrength: strength)
        let tier: (name: String, tone: DashboardTone, detail: String) = switch strength {
        case ..<0.34: ("Heavy", .good, "Text and shapes hidden")
        case ..<0.67: ("Medium", .balanced, "Shapes visible, text hidden")
        default: ("Light", .caution, "Large text may stay readable")
        }
        return SettingReading(valueText: "\(Int(radius.rounded())) pt", tierName: tier.name,
                              tone: tier.tone, detail: tier.detail)
    }

    /// `now` and `analysis.time` share the system-uptime clock.
    static func attentionReading(protectionEnabled: Bool, suspended: Bool, analysis: FrameAnalysis?,
                                 now: TimeInterval, tolerance: Double) -> AttentionMeterReading {
        guard protectionEnabled else {
            return AttentionMeterReading(statusText: "Paused", tone: .inactive, ratio: nil,
                                         detail: "Enable protection to see live head direction")
        }
        guard !suspended else {
            return AttentionMeterReading(statusText: "Suspended", tone: .inactive, ratio: nil,
                                         detail: "Resumes when the Mac wakes")
        }
        guard let analysis, now - analysis.time <= staleAnalysisAge else {
            return AttentionMeterReading(statusText: "Waiting for camera…", tone: .inactive, ratio: nil,
                                         detail: "Camera frames are not arriving")
        }

        switch analysis.faces.count {
        case 0:
            return AttentionMeterReading(statusText: "No face detected", tone: .alert, ratio: nil,
                                         detail: lightingHint(analysis.lighting, normal: "Face the camera"))
        case 1:
            break
        default:
            return AttentionMeterReading(statusText: "\(analysis.faces.count) faces", tone: .alert, ratio: nil,
                                         detail: "Covered: only one viewer can uncover the screen")
        }

        let limits = AttentionLimits(tolerance: tolerance)
        let face = analysis.faces[0]
        guard let ratio = limits.ratio(for: face) else {
            return AttentionMeterReading(statusText: "Face unclear", tone: .caution, ratio: nil,
                                         detail: lightingHint(analysis.lighting, normal: "Hold still facing the camera"))
        }

        let radiansToDegrees = 180 / Double.pi
        var detail = "Turn \(degrees(abs(face.yaw * radiansToDegrees)))° of \(degrees(limits.yawDegrees))°"
            + " · tilt \(degrees(abs(face.pitch * radiansToDegrees)))° of \(degrees(limits.pitchDegrees))°"
        if analysis.usedLightAssist { detail += " · light assist" }
        let tone = AttentionMeterScale.tone(forRatio: ratio, recoveryFraction: AttentionLimits.recoveryFraction)
        let status = switch tone {
        case .good: "Looking at screen"
        case .caution: "Near the limit"
        default: "Looking away"
        }
        return AttentionMeterReading(statusText: status, tone: tone, ratio: ratio, detail: detail)
    }

    private static func lightingHint(_ lighting: LightingCondition, normal: String) -> String {
        switch lighting {
        case .bright: "Bright light — light assist is trying to find you"
        case .dark: "Low light — add light in front of you"
        case .normal: normal
        }
    }

    private static func degrees(_ value: Double) -> Int {
        Int(value.rounded())
    }
}
