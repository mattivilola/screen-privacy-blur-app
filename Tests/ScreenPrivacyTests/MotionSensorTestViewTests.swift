import AppKit
import XCTest
import AttentionCore
@testable import ScreenPrivacy

@MainActor
final class MotionSensorTestViewTests: XCTestCase {
    func testMetricsAndTestResultDistinguishFreshMovementFromStaleReadings() async throws {
        let view = MotionSensorTestView(frame: NSRect(x: 0, y: 0, width: 640, height: 770))
        var diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        view.update(diagnostic: diagnostic, monitorStatus: "Motion sensor present but inaccessible; using camera", now: 0)
        XCTAssertTrue(texts(view).contains("Movement detection has not been verified"))
        XCTAssertFalse(texts(view).contains(where: { $0.contains("using camera") }))
        for i in 0...30 {
            diagnostic.receive(MotionSensorReading(x: 0, y: 0, z: 1, movement: 0, time: Double(i) / 10, reportCount: UInt64(i * 10 + 1)))
        }
        for (time, count) in [(3.1, UInt64(311)), (3.2, UInt64(321)), (3.3, UInt64(331)), (3.4, UInt64(341)), (3.5, UInt64(351))] {
            diagnostic.receive(MotionSensorReading(x: 0.3, y: 0, z: 0.95, movement: 0.3, time: time, reportCount: count))
        }
        view.update(diagnostic: diagnostic, monitorStatus: "Motion sensor active", now: 3.5)
        XCTAssertTrue(texts(view).contains(where: { $0.hasPrefix("Movement detected · sensor-only test passed") }))
        XCTAssertTrue(texts(view).contains(where: { $0.contains("reports/s") }))
        view.layoutSubtreeIfNeeded()
        if let directory = ProcessInfo.processInfo.environment["SCREEN_PRIVACY_RENDER_DIR"] {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("motion-sensor-test.png"))
        }
        view.update(diagnostic: diagnostic, monitorStatus: "Motion sensor stopped reporting; using camera", now: 6)
        XCTAssertTrue(texts(view).contains("Sensor readings stopped"))
        XCTAssertFalse(texts(view).contains(where: { $0.hasPrefix("Movement detected · sensor-only test passed") }))
    }
    private func texts(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(texts)
    }
}
