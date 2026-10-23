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
            valueText: "\(Int((tolerance * 100).rounded()))%",
            tierName: tier.name,
            tone: tier.tone,
            detail: tolerance < 0.34 ? "Cover sooner when you look away" : (tolerance < 0.67 ? "Room for small, natural head movements" : "More freedom to move while reading"),
            technicalDetail: "Turn ±\(degrees(limits.yawDegrees))° · tilt ±\(degrees(limits.pitchDegrees))° · covers after \(String(format: "%.1f", limits.awayDelay)) s")
    }

    static func blurReading(_ strength: Double) -> SettingReading {
        let radius = SnapshotDisplay.blurRadiusPoints(forStrength: strength)
        let tier: (name: String, tone: DashboardTone, detail: String) = switch strength {
        case ..<0.34: ("Heavy", .balanced, "A stronger blur over the frozen screen")
        case ..<0.67: ("Medium", .balanced, "A softer view of the frozen screen")
        default: ("Light", .balanced, "Large text may remain readable")
        }
        return SettingReading(valueText: tier.name, tierName: "",
                              tone: tier.tone, detail: tier.detail, technicalDetail: "Blur radius: \(Int(radius.rounded())) points. A frozen image may remain recognizable.")
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
            return AttentionMeterReading(statusText: missingFaceStatus(analysis.lighting), tone: .alert, ratio: nil,
                                         detail: lightingHint(analysis.lighting, normal: "Face the camera"))
        case 1:
            break
        default:
            return AttentionMeterReading(statusText: "\(analysis.faces.count) faces", tone: .alert, ratio: nil,
                                         detail: "Screen covered: only one viewer can uncover it")
        }

        let limits = AttentionLimits(tolerance: tolerance)
        let face = analysis.faces[0]
        guard let ratio = limits.ratio(for: face) else {
            let status = analysis.lighting == .bright ? "Possible sun glare"
                : (analysis.lighting == .backlit ? "Strong backlight" : "Face unclear")
            return AttentionMeterReading(statusText: status, tone: .caution, ratio: nil,
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
        let guidance = switch tone {
        case .good: "Look away to try the screen cover"
        case .caution: "You’re close to the look-away boundary"
        default: "Face the camera to uncover your screen"
        }
        return AttentionMeterReading(statusText: status, tone: tone, ratio: ratio, detail: guidance, technicalDetail: detail)
    }

    private static func missingFaceStatus(_ lighting: LightingCondition) -> String {
        switch lighting {
        case .bright: "Possible sun glare"
        case .backlit: "Strong backlight"
        case .dark: "Too dark to see you"
        case .normal: "No face detected"
        }
    }

    private static func lightingHint(_ lighting: LightingCondition, normal: String) -> String {
        switch lighting {
        case .bright: "Shade the lens or turn the camera away from bright light."
        case .backlit: "Turn the camera away from the bright background, or shade the lens."
        case .dark: "Low light — add light in front of you"
        case .normal: normal
        }
    }

    private static func degrees(_ value: Double) -> Int {
        Int(value.rounded())
    }
}
