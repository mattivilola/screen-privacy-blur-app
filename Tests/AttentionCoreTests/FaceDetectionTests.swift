import XCTest
@testable import AttentionCore

final class FaceDetectionTests: XCTestCase {
    func testIsConclusive() {
        XCTAssertFalse(FaceDetectionMerge.isConclusive([]))
        XCTAssertFalse(FaceDetectionMerge.isConclusive([face(0.69)]))
        XCTAssertTrue(FaceDetectionMerge.isConclusive([face(0.7)]))
        XCTAssertTrue(FaceDetectionMerge.isConclusive([face(0.1), face(0.1)]))
    }

    func testConfidentRectangleWithoutUsablePoseStillNeedsAssist() {
        for angle: Double? in [nil, .nan, .infinity] {
            XCTAssertFalse(FaceDetectionMerge.isConclusive([
                DetectedFace(confidence: 0.99, yaw: angle, pitch: 0)
            ]))
            XCTAssertFalse(FaceDetectionMerge.isConclusive([
                DetectedFace(confidence: 0.99, yaw: 0, pitch: angle)
            ]))
        }
        XCTAssertFalse(FaceDetectionMerge.isConclusive([face(.nan)]))
        XCTAssertFalse(FaceDetectionMerge.isConclusive([face(.infinity)]))
    }

    func testAssistCanRecoverPoseWithoutLoweringConfidenceThreshold() {
        let noPose = [DetectedFace(confidence: 0.99, yaw: nil, pitch: nil)]
        let usable = [face(0.75)]
        let tooWeak = [face(0.69)]
        XCTAssertEqual(FaceDetectionMerge.preferred(noPose, usable), usable)
        XCTAssertEqual(FaceDetectionMerge.preferred(usable, noPose), usable)
        XCTAssertEqual(FaceDetectionMerge.preferred(noPose, tooWeak), noPose)
        var state = AttentionState()
        let recovered = FaceDetectionMerge.poses(FaceDetectionMerge.preferred(noPose, usable))
        XCTAssertTrue(state.update(faces: recovered, at: 0))
        XCTAssertFalse(state.update(faces: recovered, at: 0.5))
        // A second detected person must still override a usable single pose.
        let multiple = [face(0.2), face(0.2)]
        XCTAssertTrue(state.update(faces: FaceDetectionMerge.poses(
            FaceDetectionMerge.preferred(usable, multiple)), at: 0.75))
    }

    func testAutomaticLightAssistAdaptsAndStaysBounded() {
        let shaded = LightAssistAdjustment(centerMeanLuma: 0.1, highlightFraction: 0.2)
        let indoor = LightAssistAdjustment(centerMeanLuma: 0.5, highlightFraction: 0.01)
        let sunny = LightAssistAdjustment(centerMeanLuma: 0.85, highlightFraction: 0.6)
        XCTAssertLessThan(shaded.shadowGamma, indoor.shadowGamma)
        XCTAssertLessThan(sunny.highlightEV, indoor.highlightEV)
        for value in [-10.0, 0, 0.5, 1, 10, .nan, .infinity] {
            let adjustment = LightAssistAdjustment(centerMeanLuma: value, highlightFraction: value)
            XCTAssertTrue((0.4...0.85).contains(adjustment.shadowGamma))
            XCTAssertTrue((-1.5 ... -0.4).contains(adjustment.highlightEV))
        }
    }

    func testShadedCenterAgainstSkyIsBacklitEvenWithNormalFrameAverage() {
        XCTAssertEqual(LightingCondition.classify(meanLuma: 0.5, highlightFraction: 0.2,
            shadowFraction: 0.1, centerMeanLuma: 0.2), .backlit)
        XCTAssertEqual(LightingCondition.classify(meanLuma: 0.5, highlightFraction: 0.01,
            shadowFraction: 0.1, centerMeanLuma: 0.4), .normal)
        XCTAssertEqual(LightingCondition.classify(meanLuma: 0.5, highlightFraction: 0.01,
            shadowFraction: 0.1, centerMeanLuma: 0.2), .normal)
    }

    func testPreferredNeverLetsALaterPassHideAFace() {
        let one = [face(0.9)]
        let two = [face(0.4), face(0.4)]
        XCTAssertEqual(FaceDetectionMerge.preferred(one, two), two)
        XCTAssertEqual(FaceDetectionMerge.preferred(two, one), two)
        XCTAssertEqual(FaceDetectionMerge.preferred([], one), one)
        XCTAssertEqual(FaceDetectionMerge.preferred(one, []), one)
    }

    func testPreferredComparesWeakestConfidenceForEqualCounts() {
        let weak = [face(0.3)]
        let strong = [face(0.8)]
        XCTAssertEqual(FaceDetectionMerge.preferred(weak, strong), strong)
        XCTAssertEqual(FaceDetectionMerge.preferred(strong, weak), strong)

        let mixed = [face(0.9), face(0.2)]
        let even = [face(0.5), face(0.5)]
        XCTAssertEqual(FaceDetectionMerge.preferred(mixed, even), even)
    }

    func testPreferredKeepsCurrentOnTie() {
        let current = [DetectedFace(confidence: 0.6, yaw: 0.1, pitch: 0.1)]
        let candidate = [DetectedFace(confidence: 0.6, yaw: 0.2, pitch: 0.2)]
        XCTAssertEqual(FaceDetectionMerge.preferred(current, candidate), current)
    }

    func testPosesGateAnglesByConfidenceAndKeepEveryFace() {
        let poses = FaceDetectionMerge.poses([
            DetectedFace(confidence: 0.9, yaw: 0.1, pitch: -0.2),
            DetectedFace(confidence: 0.69, yaw: 0.1, pitch: 0.1),
            DetectedFace(confidence: 0.95, yaw: nil, pitch: 0.1),
            DetectedFace(confidence: 0.95, yaw: 0.1, pitch: nil)
        ])
        XCTAssertEqual(poses.count, 4)
        XCTAssertEqual(poses[0].yaw, 0.1)
        XCTAssertEqual(poses[0].pitch, -0.2)
        for invalid in poses.dropFirst() {
            XCTAssertTrue(invalid.yaw.isNaN && invalid.pitch.isNaN)
        }
        XCTAssertTrue(FaceDetectionMerge.poses([]).isEmpty)
    }

    func testLightingClassification() {
        func classify(_ mean: Double, _ highlights: Double, _ shadows: Double) -> LightingCondition {
            LightingCondition.classify(meanLuma: mean, highlightFraction: highlights, shadowFraction: shadows)
        }
        XCTAssertEqual(classify(0.5, 0.05, 0.05), .normal)
        XCTAssertEqual(classify(0.76, 0, 0), .bright)
        XCTAssertEqual(classify(0.75, 0, 0), .normal)
        XCTAssertEqual(classify(0.5, 0.31, 0), .bright)
        XCTAssertEqual(classify(0.5, 0.30, 0), .normal)
        XCTAssertEqual(classify(0.14, 0, 0), .dark)
        XCTAssertEqual(classify(0.15, 0, 0), .normal)
        XCTAssertEqual(classify(0.5, 0, 0.61), .dark)
        XCTAssertEqual(classify(0.5, 0, 0.60), .normal)
        // Bright is checked first when both conditions hold (a high-contrast backlit scene).
        XCTAssertEqual(classify(0.1, 0.4, 0.7), .bright)
    }

    func testNonFiniteLightingInputsAreNormal() {
        XCTAssertEqual(LightingCondition.classify(meanLuma: .nan, highlightFraction: 0.9, shadowFraction: 0), .normal)
        XCTAssertEqual(LightingCondition.classify(meanLuma: 0.5, highlightFraction: .infinity, shadowFraction: 0), .normal)
        XCTAssertEqual(LightingCondition.classify(meanLuma: 0.01, highlightFraction: 0, shadowFraction: .nan), .normal)
    }

    private func face(_ confidence: Double) -> DetectedFace {
        DetectedFace(confidence: confidence, yaw: 0, pitch: 0)
    }
}
