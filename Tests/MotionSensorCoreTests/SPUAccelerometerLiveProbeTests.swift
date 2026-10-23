import Foundation
import XCTest
@testable import MotionSensorCore

/// Opt-in, read-only hardware probe. Set SPU_ACCELEROMETER_LIVE_PROBE=1 to collect
/// a bounded three-second report count on the Mac running the test.
@MainActor
final class SPUAccelerometerLiveProbeTests: XCTestCase {
    func testReadOnlyPhysicalProbeForThreeSeconds() throws {
        guard ProcessInfo.processInfo.environment["SPU_ACCELEROMETER_LIVE_PROBE"] == "1" else {
            throw XCTSkip("Set SPU_ACCELEROMETER_LIVE_PROBE=1 to run the three-second hardware probe.")
        }

        let stream = SPUAccelerometerStream()
        defer { stream.stop() }
        stream.start()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.05)))
        }

        let latest = stream.latestReport
        print("SPU probe: status=\(stream.status.description), validReports=\(stream.reportCount), lastReportTime=\(latest?.captureTime.description ?? "none")")
        if let latest {
            XCTAssertEqual(latest.rawReport.count, SPUAccelerometerStream.reportLength)
            XCTAssertEqual(latest.sequence, stream.reportCount)
        }
    }
}
