import AttentionCore
import XCTest
@testable import ScreenPrivacy

@MainActor
final class MotionSensorTestSessionTests: XCTestCase {
    func testSleepResetsPassedTestEvenWhenUptimeDoesNotAdvanceAndRejectsOldCallbacks() async {
        let monitor = FakeSensor()
        var now = 0.0
        let session = MotionSensorTestSession(sensitivity: 0.5, monitor: monitor, now: { now })
        session.start()
        let old = monitor.callback!
        for i in 0...30 {
            now = Double(i) / 10
            old(reading(now, count: UInt64(i * 10 + 1)))
        }
        now = 3.1; old(reading(now, movement: 0.5, count: 311))
        for time in [3.2, 3.3, 3.4, 3.5] { now = time; old(reading(now, movement: 0.5, count: UInt64(time * 1000))) }
        XCTAssertTrue(session.diagnostic.detectedMovement)
        session.pauseForSleep()
        XCTAssertNil(session.diagnostic.latest)
        XCTAssertFalse(session.diagnostic.detectedMovement)
        // systemUptime need not include the time spent asleep.
        session.resumeAfterWake()
        XCTAssertEqual(monitor.starts, 2)
        old(reading(now, movement: 1, count: 342))
        XCTAssertNil(session.diagnostic.latest)
        monitor.callback!(reading(now, count: 1))
        XCTAssertEqual(session.diagnostic.phase, .countdown(until: 6.5))
        XCTAssertFalse(session.diagnostic.detectedMovement)
        session.stop()
    }
    func testSensitivityChangesResetTheSilentPolicyAndMatchTheCurrentAlarmSetting() async {
        let monitor = FakeSensor()
        let session = MotionSensorTestSession(sensitivity: 0, monitor: monitor, now: { 0 })
        session.start()
        monitor.callback!(reading(0, count: 1))
        session.setSensitivity(1)
        XCTAssertEqual(session.diagnostic.threshold, 0.02, accuracy: 0.001)
        XCTAssertNil(session.diagnostic.latest)
        XCTAssertFalse(session.diagnostic.detectedMovement)
        session.stop()
    }
    func testDelayedDeliveriesAreRejectedAndClosedTestsDoNotRestartOnWake() async {
        let monitor = FakeSensor()
        let session = MotionSensorTestSession(sensitivity: 0.5, monitor: monitor, now: { 10 })
        session.start()
        monitor.callback!(reading(1, movement: 1, count: 1))
        XCTAssertNil(session.diagnostic.latest)
        session.pauseForSleep(); session.stop(); session.resumeAfterWake()
        XCTAssertEqual(monitor.starts, 1)
        XCTAssertGreaterThanOrEqual(monitor.stops, 2)
    }
    private func reading(_ time: TimeInterval, movement: Double = 0, count: UInt64) -> MotionSensorReading {
        MotionSensorReading(x: 0, y: 0, z: 1, movement: movement, time: time, reportCount: count)
    }
}

@MainActor
private final class FakeSensor: MotionSensorReadingSource {
    let statusText = "Fake sensor for deterministic tests"
    var callback: (@MainActor @Sendable (MotionSensorReading) -> Void)?
    var starts = 0, stops = 0
    func startSamples(onSample: @escaping @MainActor @Sendable (MotionSensorReading) -> Void) {
        starts += 1; callback = onSample
    }
    func stop() { stops += 1; callback = nil }
}
