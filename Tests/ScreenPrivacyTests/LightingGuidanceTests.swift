import AttentionCore
import OverlayUI
import XCTest
@testable import ScreenPrivacy

final class LightingGuidanceTests: XCTestCase {
    func testFailedDetectionInHarshLightOffersAnAction() {
        for lighting in [LightingCondition.bright, .backlit] {
            for faces in [[], [FacePose(yaw: .nan, pitch: .nan)]] {
                let reading = reading(lighting, faces: faces)
                XCTAssertTrue(reading.detail.contains("shade") || reading.detail.contains("Shade"))
                XCTAssertTrue(reading.detail.contains("camera"))
                XCTAssertNotEqual(reading.statusText, "No face detected")
                XCTAssertNil(reading.ratio)
            }
        }
    }

    func testGlareAdviceDoesNotOverrideRealAttentionOrOtherFailures() {
        XCTAssertEqual(reading(.bright, faces: [FacePose(yaw: 0, pitch: 0)]).statusText, "Looking at screen")
        XCTAssertEqual(reading(.bright, faces: [FacePose(yaw: 0, pitch: 0), FacePose(yaw: 0, pitch: 0)]).statusText, "2 faces")
        XCTAssertEqual(reading(.normal, faces: []).statusText, "No face detected")
        XCTAssertEqual(reading(.dark, faces: []).statusText, "Too dark to see you")
        XCTAssertEqual(reading(.bright, faces: [], now: 3).statusText, "Waiting for camera…")
    }

    private func reading(_ lighting: LightingCondition, faces: [FacePose], now: Double = 1) -> OverlayUI.AttentionMeterReading {
        DashboardFormatting.attentionReading(protectionEnabled: true, suspended: false,
            analysis: FrameAnalysis(faces: faces, time: 1, lighting: lighting, usedLightAssist: false,
                                    motionScore: nil, isObscured: false), now: now, tolerance: 0.5)
    }
}
