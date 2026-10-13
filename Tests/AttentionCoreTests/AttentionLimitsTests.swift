import XCTest
@testable import AttentionCore

final class AttentionLimitsTests: XCTestCase {
    func testLimitsAtToleranceEndpointsAndMidpoint() {
        let strict = AttentionLimits(tolerance: 0)
        XCTAssertEqual(strict.yawDegrees, 12, accuracy: 1e-9)
        XCTAssertEqual(strict.pitchDegrees, 12, accuracy: 1e-9)
        XCTAssertEqual(strict.awayDelay, 0.35, accuracy: 1e-9)

        let balanced = AttentionLimits(tolerance: 0.5)
        XCTAssertEqual(balanced.yawDegrees, 23.5, accuracy: 1e-9)
        XCTAssertEqual(balanced.pitchDegrees, 21, accuracy: 1e-9)
        XCTAssertEqual(balanced.awayDelay, 0.8, accuracy: 1e-9)

        let relaxed = AttentionLimits(tolerance: 1)
        XCTAssertEqual(relaxed.yawDegrees, 35, accuracy: 1e-9)
        XCTAssertEqual(relaxed.pitchDegrees, 30, accuracy: 1e-9)
        XCTAssertEqual(relaxed.awayDelay, 1.25, accuracy: 1e-9)
    }

    func testToleranceIsNormalizedLikeAttentionState() {
        XCTAssertEqual(AttentionLimits(tolerance: .nan), AttentionLimits(tolerance: 0.5))
        XCTAssertEqual(AttentionLimits(tolerance: .infinity), AttentionLimits(tolerance: 0.5))
        XCTAssertEqual(AttentionLimits(tolerance: -4), AttentionLimits(tolerance: 0))
        XCTAssertEqual(AttentionLimits(tolerance: 7), AttentionLimits(tolerance: 1))
    }

    func testRatioUsesTheWorseAxisAndIgnoresSign() throws {
        let limits = AttentionLimits(tolerance: 0)
        XCTAssertEqual(try XCTUnwrap(limits.ratio(for: pose())), 0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(limits.ratio(for: pose(yaw: 6))), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(limits.ratio(for: pose(yaw: -6))), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(limits.ratio(for: pose(pitch: -12))), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(limits.ratio(for: pose(yaw: 3, pitch: 18))), 1.5, accuracy: 1e-9)
    }

    func testRatioIsNilForNonFinitePose() {
        let limits = AttentionLimits(tolerance: 0.5)
        XCTAssertNil(limits.ratio(for: FacePose(yaw: .nan, pitch: 0)))
        XCTAssertNil(limits.ratio(for: FacePose(yaw: 0, pitch: .infinity)))
    }

    func testRecoveryFractionMatchesAttentionStateReturnRange() {
        XCTAssertEqual(AttentionLimits.recoveryFraction, 0.8)
    }

    private func pose(yaw: Double = 0, pitch: Double = 0) -> FacePose {
        FacePose(yaw: yaw * .pi / 180, pitch: pitch * .pi / 180)
    }
}
