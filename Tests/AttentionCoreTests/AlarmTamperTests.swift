import XCTest
@testable import AttentionCore

final class AlarmTamperTests: XCTestCase {
    func testCameraLossAndLidClosureRequireSustainedArmedEvidence() {
        var s = AlarmTamperEvidence()
        XCTAssertFalse(s.update(armed: false, lidClosed: true, cameraAvailable: false, obscured: false, at: 0))
        for time in stride(from: 1.0, through: 2.75, by: 0.25) {
            XCTAssertFalse(s.update(armed: true, lidClosed: true, cameraAvailable: true, obscured: false, at: time))
        }
        XCTAssertTrue(s.update(armed: true, lidClosed: true, cameraAvailable: true, obscured: false, at: 3))
    }
    func testDropoutRecoveryAndEvidenceGapsCancelTheGracePeriod() {
        var s = AlarmTamperEvidence()
        XCTAssertFalse(s.update(armed: true, lidClosed: false, cameraAvailable: false, obscured: false, at: 0))
        XCTAssertFalse(s.update(armed: true, lidClosed: false, cameraAvailable: true, obscured: false, at: 0.5))
        XCTAssertFalse(s.update(armed: true, lidClosed: false, cameraAvailable: false, obscured: false, at: 1))
        XCTAssertFalse(s.update(armed: true, lidClosed: false, cameraAvailable: false, obscured: false, at: 5))
        s.reset()
        XCTAssertFalse(s.update(armed: true, lidClosed: false, cameraAvailable: true, obscured: true, at: 6))
    }
}
