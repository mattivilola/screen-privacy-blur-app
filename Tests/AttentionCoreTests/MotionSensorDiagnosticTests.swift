import XCTest
@testable import AttentionCore

final class MotionSensorDiagnosticTests: XCTestCase {
    func testReportDecodesSignedLittleEndianGAndRejectsUnknownLengths() {
        var bytes = [UInt8](repeating: 0, count: 22)
        for (offset, value) in [(6, Int32(65_536)), (10, Int32(-32_768)), (14, Int32(16_384))] {
            let bits = UInt32(bitPattern: value)
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: bits >> (i * 8)) }
        }
        let axes = MotionSensorReport.axes(bytes)!
        XCTAssertEqual(axes.x, 1); XCTAssertEqual(axes.y, -0.5); XCTAssertEqual(axes.z, 0.25)
        XCTAssertNil(MotionSensorReport.axes(Array(bytes.dropLast())))
        XCTAssertNil(MotionSensorReport.axes(bytes + [0]))
    }
    func testFilterRemovesGravityAndUsesTheAlarmNoiseFloor() {
        var filter = MotionSensorFilter()
        let first = filter.sample(x: 0, y: 0, z: 1, at: 0)!
        XCTAssertEqual(first.magnitude, 1); XCTAssertEqual(first.movement, 0)
        let still = filter.sample(x: 0, y: 0, z: 1, at: 0.01)!
        XCTAssertEqual(still.movement, 0); XCTAssertEqual(still.reportCount, 2)
        let tilted = filter.sample(x: 0.5, y: 0, z: 0.9, at: 0.02)!
        XCTAssertGreaterThan(tilted.movement, 0.4)
        let afterGap = filter.sample(x: 0.5, y: 0, z: 0.9, at: 3)!
        XCTAssertEqual(afterGap.movement, 0)
        XCTAssertNil(filter.sample(x: .nan, y: 0, z: 1, at: 4))
    }
    func testSilentSensorTestCalibratesThenRequiresSustainedMovement() {
        var diagnostic = calibrated()
        XCTAssertEqual(diagnostic.phase, .armed)
        diagnostic.receive(reading(time: 3.1, score: 0.5, count: 311))
        XCTAssertFalse(diagnostic.detectedMovement)
        diagnostic.receive(reading(time: 3.2, score: 0.5, count: 321))
        XCTAssertFalse(diagnostic.detectedMovement)
        diagnostic.receive(reading(time: 3.3, score: 0.5, count: 331))
        diagnostic.receive(reading(time: 3.4, score: 0.5, count: 341))
        diagnostic.receive(reading(time: 3.5, score: 0.5, count: 351))
        XCTAssertTrue(diagnostic.detectedMovement)
        XCTAssertTrue(diagnostic.isFresh(at: 3.5))
        XCTAssertFalse(diagnostic.isFresh(at: 5.1))
        diagnostic.receive(reading(time: 6, score: 0, count: 601))
        XCTAssertFalse(diagnostic.detectedMovement)
        XCTAssertEqual(diagnostic.phase, .countdown(until: 9))
    }
    func testReportRateUsesHardwareCountRatherThanUIUpdatesAndHistoryIsBounded() {
        var diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        for i in 0...200 { diagnostic.receive(reading(time: Double(i) * 0.05, score: 0, count: UInt64(i * 5 + 1))) }
        XCTAssertEqual(diagnostic.reportRate!, 100, accuracy: 0.01)
        XCTAssertEqual(diagnostic.observedReports, 1001)
        XCTAssertLessThanOrEqual(diagnostic.samples.count, 121)
        XCTAssertFalse(diagnostic.isFresh(at: 9))
        XCTAssertEqual(diagnostic.threshold, 0.0632456, accuracy: 0.001)
    }
    func testResetAndInvalidOrReorderedReadingsCannotPassTheTest() {
        var diagnostic = calibrated()
        let count = diagnostic.samples.count
        diagnostic.receive(reading(time: 1, score: 1, count: 101))
        diagnostic.receive(reading(time: 4, score: .nan, count: 401))
        XCTAssertEqual(diagnostic.samples.count, count)
        XCTAssertFalse(diagnostic.detectedMovement)
        diagnostic.reset(sensitivity: 1)
        XCTAssertNil(diagnostic.latest); XCTAssertEqual(diagnostic.observedReports, 0)
        XCTAssertEqual(diagnostic.peak, 0); XCTAssertEqual(diagnostic.threshold, 0.02, accuracy: 0.001)
        XCTAssertFalse(diagnostic.isFresh(at: 5.1))
    }
    private func calibrated() -> MotionSensorDiagnostic {
        var diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        for i in 0...30 { diagnostic.receive(reading(time: Double(i) / 10, score: 0, count: UInt64(i * 10 + 1))) }
        return diagnostic
    }
    private func reading(time: TimeInterval, score: Double, count: UInt64) -> MotionSensorReading {
        MotionSensorReading(x: 0, y: 0, z: 1, movement: score, time: time, reportCount: count)
    }
}
