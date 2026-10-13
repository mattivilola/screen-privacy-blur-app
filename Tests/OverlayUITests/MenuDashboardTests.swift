import XCTest
@testable import OverlayUI

final class MenuDashboardTests: XCTestCase {
    func testFillFractionScalesAndClamps() {
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: 0), 0)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: 0.75), 0.5, accuracy: 1e-9)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: 1), 1 / 1.5, accuracy: 1e-9)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: 1.5), 1)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: 4), 1)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: -0.3), 0)
    }

    func testFillFractionIsEmptyForNonFiniteRatios() {
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: .nan), 0)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: .infinity), 0)
        XCTAssertEqual(AttentionMeterScale.fillFraction(for: -.infinity), 0)
    }

    func testToneBoundaries() {
        let recovery = 0.8
        XCTAssertEqual(AttentionMeterScale.tone(forRatio: 0, recoveryFraction: recovery), .good)
        XCTAssertEqual(AttentionMeterScale.tone(forRatio: 0.8, recoveryFraction: recovery), .good)
        XCTAssertEqual(AttentionMeterScale.tone(forRatio: 0.800_001, recoveryFraction: recovery), .caution)
        XCTAssertEqual(AttentionMeterScale.tone(forRatio: 1, recoveryFraction: recovery), .caution)
        XCTAssertEqual(AttentionMeterScale.tone(forRatio: 1.000_001, recoveryFraction: recovery), .alert)
        XCTAssertEqual(AttentionMeterScale.tone(forRatio: 3, recoveryFraction: recovery), .alert)
    }
}
