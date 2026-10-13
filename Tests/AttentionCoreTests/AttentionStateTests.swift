import XCTest
@testable import AttentionCore

final class AttentionStateTests: XCTestCase {
    func testStartsCoveredAndRequiresContinuousLookingToRecover() {
        var state = AttentionState(tolerance: 0)

        XCTAssertTrue(state.isCovered)
        XCTAssertTrue(state.update(faces: [pose()], at: 0))
        XCTAssertTrue(state.update(faces: [pose()], at: 0.34))
        XCTAssertFalse(state.update(faces: [pose()], at: 0.35))
    }

    func testAHeadAngleAtAwayBoundaryDoesNotChatterAfterRecovery() {
        var state = AttentionState(tolerance: 0)
        recover(&state)

        // 10 degrees is outside the stricter 9.6-degree return limit but inside
        // the 12-degree away limit, so an already-uncovered screen stays open.
        XCTAssertFalse(state.update(faces: [pose(yaw: 10)], at: 0.36))
        XCTAssertFalse(state.update(faces: [pose(yaw: 12)], at: 0.70))
        XCTAssertFalse(state.update(faces: [pose(yaw: 12.01)], at: 0.71))
        XCTAssertTrue(state.update(faces: [pose(yaw: 12.01)], at: 1.06))
    }

    func testToleranceChangesAngleAndAwayDelay() {
        var strict = AttentionState(tolerance: 0)
        recover(&strict)
        XCTAssertFalse(strict.update(faces: [pose(yaw: 20)], at: 0.36))
        XCTAssertTrue(strict.update(faces: [pose(yaw: 20)], at: 0.71))

        var tolerant = AttentionState(tolerance: 1)
        recover(&tolerant)
        XCTAssertFalse(tolerant.update(faces: [pose(yaw: 20)], at: 0.36))

        tolerant.tolerance = .infinity
        XCTAssertEqual(tolerant.tolerance, 0.5)
        tolerant.tolerance = -2
        XCTAssertEqual(tolerant.tolerance, 0)
        tolerant.tolerance = 2
        XCTAssertEqual(tolerant.tolerance, 1)
    }

    func testToleranceChangeDiscardsRecoveryEvidenceFromPriorThreshold() {
        var state = AttentionState(tolerance: 1)

        XCTAssertTrue(state.update(faces: [pose(yaw: 20)], at: 0))
        state.tolerance = 0
        XCTAssertTrue(state.update(faces: [pose()], at: 0.20))
        XCTAssertTrue(state.update(faces: [pose()], at: 0.35))
        XCTAssertFalse(state.update(faces: [pose()], at: 0.55))
    }

    func testNoFaceUsesAwayDebounceButMultipleFacesCoverImmediately() {
        var state = AttentionState(tolerance: 0)
        recover(&state)

        XCTAssertFalse(state.update(faces: [], at: 0.36))
        XCTAssertFalse(state.update(faces: [], at: 0.70))
        XCTAssertTrue(state.update(faces: [], at: 0.71))

        recover(&state, startingAt: 0.72)
        XCTAssertTrue(state.update(faces: [pose(), pose()], at: 1.08))
    }

    func testInvalidPoseAndUnavailableCoverAndDiscardRecoveryEvidence() {
        var state = AttentionState()
        recover(&state)

        // An unclear single face is debounced like a missing face (0.8 s at the default tolerance).
        XCTAssertFalse(state.update(faces: [FacePose(yaw: .nan, pitch: 0)], at: 0.36))
        XCTAssertTrue(state.update(faces: [FacePose(yaw: .nan, pitch: 0)], at: 1.16))

        // While covered, an unclear frame discards recovery evidence.
        XCTAssertTrue(state.update(faces: [pose()], at: 1.17))
        XCTAssertTrue(state.update(faces: [FacePose(yaw: 0, pitch: .infinity)], at: 1.30))
        XCTAssertTrue(state.update(faces: [pose()], at: 1.52))
        XCTAssertTrue(state.update(faces: [pose()], at: 1.86))
        XCTAssertFalse(state.update(faces: [pose()], at: 1.87))

        XCTAssertTrue(state.unavailable())
        XCTAssertTrue(state.update(faces: [pose()], at: 2.0))
        XCTAssertFalse(state.update(faces: [pose()], at: 2.35))
    }

    func testInvalidPoseCoversOnlyAfterAwayDelay() {
        var state = AttentionState(tolerance: 0)
        recover(&state)
        let unclear = FacePose(yaw: .nan, pitch: .nan)

        XCTAssertFalse(state.update(faces: [unclear], at: 0.4))
        XCTAssertFalse(state.update(faces: [unclear], at: 0.74))
        XCTAssertTrue(state.update(faces: [unclear], at: 0.75))
    }

    func testInvalidPoseWhileCoveredNeverUncoversAndResetsRecoveryEvidence() {
        var state = AttentionState(tolerance: 0)
        let unclear = FacePose(yaw: .nan, pitch: .nan)

        XCTAssertTrue(state.update(faces: [pose()], at: 0))
        XCTAssertTrue(state.update(faces: [unclear], at: 0.2))
        // The earlier look no longer counts: recovery restarts at 0.4.
        XCTAssertTrue(state.update(faces: [pose()], at: 0.4))
        XCTAssertTrue(state.update(faces: [pose()], at: 0.74))
        XCTAssertFalse(state.update(faces: [pose()], at: 0.75))

        var unclearOnly = AttentionState(tolerance: 0)
        for step in 0..<20 {
            XCTAssertTrue(unclearOnly.update(faces: [unclear], at: Double(step) * 0.25))
        }
    }

    func testValidLookBetweenInvalidFramesCancelsAwayTimer() {
        var state = AttentionState(tolerance: 0)
        recover(&state)
        let unclear = FacePose(yaw: .nan, pitch: .nan)

        XCTAssertFalse(state.update(faces: [unclear], at: 0.4))
        XCTAssertFalse(state.update(faces: [pose()], at: 0.6))
        XCTAssertFalse(state.update(faces: [unclear], at: 0.8))
        XCTAssertFalse(state.update(faces: [unclear], at: 1.0))
        XCTAssertTrue(state.update(faces: [unclear], at: 1.15))
    }

    func testOutOfOrderAndLargeGapsResetEvidenceAndCover() {
        var state = AttentionState()
        XCTAssertTrue(state.update(faces: [pose()], at: 10))
        XCTAssertTrue(state.update(faces: [pose()], at: 9.9))
        XCTAssertTrue(state.update(faces: [pose()], at: 10.35))
        XCTAssertFalse(state.update(faces: [pose()], at: 10.70))

        XCTAssertTrue(state.update(faces: [pose()], at: 12.0))
        XCTAssertTrue(state.update(faces: [pose()], at: 12.34))
        XCTAssertFalse(state.update(faces: [pose()], at: 12.69))
    }

    func testOutOfOrderObservationRecoversPrivacyFromAnUncoveredState() {
        var state = AttentionState()
        recover(&state)

        XCTAssertTrue(state.update(faces: [pose()], at: 0.20))
    }

    func testBriefAbsenceCancelsAwayTimerWhenAttentionReturns() {
        var state = AttentionState(tolerance: 0)
        recover(&state)
        XCTAssertFalse(state.update(faces: [], at: 0.4))
        XCTAssertFalse(state.update(faces: [pose()], at: 0.6))
        XCTAssertFalse(state.update(faces: [], at: 0.8))
        XCTAssertFalse(state.update(faces: [], at: 1.0))
        XCTAssertTrue(state.update(faces: [], at: 1.15))
    }

    func testForgivingPitchThresholdStillCoversAfterMaximumDelay() {
        var state = AttentionState(tolerance: 1)
        recover(&state)
        XCTAssertFalse(state.update(faces: [pose(pitch: 30)], at: 0.4))
        XCTAssertFalse(state.update(faces: [pose(pitch: 31)], at: 0.5))
        XCTAssertFalse(state.update(faces: [pose(pitch: 31)], at: 1.0))
        XCTAssertFalse(state.update(faces: [pose(pitch: 31)], at: 1.74))
        XCTAssertTrue(state.update(faces: [pose(pitch: 31)], at: 1.75))
        XCTAssertTrue(state.update(faces: [pose()], at: .nan))
    }

    private func recover(_ state: inout AttentionState, startingAt time: TimeInterval = 0) {
        XCTAssertTrue(state.update(faces: [pose()], at: time))
        XCTAssertFalse(state.update(faces: [pose()], at: time + 0.35))
    }

    private func pose(yaw: Double = 0, pitch: Double = 0) -> FacePose {
        FacePose(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180)
    }
}
