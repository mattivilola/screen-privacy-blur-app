import XCTest
@testable import AttentionCore

final class AlarmStateTests: XCTestCase {
    func testCountdownOnlyWhileAwayAndReturningCancelsBeforeArming() {
        var s = AlarmState(); s.enable()
        s.observe(watching: true, at: 0); XCTAssertEqual(s.phase, .waiting)
        s.observe(watching: false, at: 1); XCTAssertEqual(s.phase, .countdown(until: 11))
        s.observe(watching: true, at: 10); XCTAssertEqual(s.phase, .waiting)
        s.observe(watching: false, at: 11); s.observe(watching: false, at: 21)
        XCTAssertEqual(s.phase, .armed)
        s.observe(watching: true, at: 22); XCTAssertEqual(s.phase, .armed)
    }
    func testMotionNeedsSustainedFreshEvidenceFromSameSourceAndLatches() {
        var s = armed()
        s.motion(1, source: "camera", at: 11)
        s.motion(0, source: "sensor", at: 11.1)
        XCTAssertEqual(s.phase, .armed)
        s.motion(1, source: "camera", at: 11.25)
        XCTAssertEqual(s.phase, .alarming)
        s.observe(watching: true, at: 12); XCTAssertEqual(s.phase, .alarming)
        s.disable(); XCTAssertEqual(s.phase, .off)
    }
    func testStaleMotionSuspensionAndLowScoresDiscardEvidence() {
        var s = armed()
        s.motion(1, source: "camera", at: 11)
        s.motion(1, source: "camera", at: 13); XCTAssertEqual(s.phase, .armed)
        s.interrupt()
        s.motion(1, source: "camera", at: 13.3); XCTAssertEqual(s.phase, .armed)
        s.motion(0, source: "camera", at: 13.4)
        s.motion(1, source: "camera", at: 13.6); XCTAssertEqual(s.phase, .armed)
        s.motion(.nan, source: "camera", at: 14)
    }
    func testSensitivityAndExposureCompensation() {
        var s = AlarmState(); s.sensitivity = 0; XCTAssertEqual(s.threshold, 0.20, accuracy: 0.001)
        s.sensitivity = 1; XCTAssertEqual(s.threshold, 0.03, accuracy: 0.001)
        var motion = CameraMotionEvidence()
        XCTAssertNil(motion.score([0.1, 0.2, 0.3, 0.4]))
        XCTAssertEqual(motion.score([0.2, 0.3, 0.4, 0.5])!, 0, accuracy: 0.001)
        XCTAssertGreaterThan(motion.score([0.7, 0.1, 0.6, 0.1])!, 0.2)
        motion.reset(); XCTAssertNil(motion.score([0.1]))
    }
    func testNeedsAttentionBeforeDepartureAndSettledFramesBeforeArming() {
        var s = AlarmState(); s.enable()
        s.observe(watching: false, at: 0); s.observe(watching: false, at: 30)
        XCTAssertEqual(s.phase, .waiting)
        s.observe(watching: true, at: 31); s.observe(watching: false, cameraMotion: 1, at: 32)
        s.observe(watching: false, cameraMotion: 1, at: 42)
        XCTAssertEqual(s.phase, .countdown(until: 42))
        s.observe(watching: false, cameraMotion: 0, at: 43)
        XCTAssertEqual(s.phase, .countdown(until: 42))
        s.observe(watching: false, cameraMotion: 0, at: 44)
        XCTAssertEqual(s.phase, .armed)
    }
    func testSuspendedCountdownRequiresFreshAttention() {
        var s = AlarmState(); s.enable(); s.observe(watching: true, at: 0)
        s.observe(watching: false, at: 1); s.interrupt()
        s.observe(watching: false, at: 20); XCTAssertEqual(s.phase, .waiting)
    }
    private func armed() -> AlarmState {
        var s = AlarmState(); s.enable(); s.observe(watching: true, at: -1); s.observe(watching: false, at: 0); s.observe(watching: false, at: 10); return s
    }
}
