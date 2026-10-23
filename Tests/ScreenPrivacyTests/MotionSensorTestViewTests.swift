import AppKit
import XCTest
import AttentionCore
@testable import ScreenPrivacy

@MainActor
final class MotionSensorTestViewTests: XCTestCase {
    func testUnavailableStateGuidesRetryAndKeepsTechnicalValuesCollapsed() {
        let view = MotionSensorTestView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 500),
            protectionWasEnabled: false
        )
        let diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)

        view.update(
            diagnostic: diagnostic,
            monitorStatus: "Motion sensor present but inaccessible; using camera",
            now: 0
        )

        let visible = texts(view)
        XCTAssertTrue(visible.contains("Sensor unavailable"))
        XCTAssertTrue(visible.contains(where: { $0.contains("Retry sensor") }))
        XCTAssertTrue(visible.contains(where: { $0.contains("screen protection are off") }))
        XCTAssertTrue(view.retryButton.isHidden == false)
        XCTAssertTrue(view.resetButton.isHidden)
        XCTAssertTrue(view.detailsButton.state == .off)
        XCTAssertFalse(visible.contains(where: { $0.contains("using camera") }))
        XCTAssertFalse(visible.contains(where: { $0.contains("X / Y / Z") }))
        XCTAssertFalse(visible.contains(where: { $0.contains("reports/s") }))
    }

    func testStillReadyPassedAndStaleStatesUseActualDiagnosticEvidence() {
        let view = MotionSensorTestView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
        var diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        for i in 0...29 {
            diagnostic.receive(MotionSensorReading(x: 0, y: 0, z: 1, movement: 0, time: Double(i) / 10, reportCount: UInt64(i * 10 + 1)))
        }

        view.update(diagnostic: diagnostic, monitorStatus: "Motion sensor active", now: 2.9)
        XCTAssertTrue(texts(view).contains("Keep the Mac still"))
        XCTAssertTrue(view.resetButton.isHidden)

        diagnostic.receive(MotionSensorReading(x: 0, y: 0, z: 1, movement: 0, time: 3.0, reportCount: 301))
        for (time, count) in [(3.1, UInt64(311)), (3.2, UInt64(321)), (3.3, UInt64(331)), (3.4, UInt64(341)), (3.5, UInt64(351))] {
            diagnostic.receive(MotionSensorReading(x: 0.3, y: 0, z: 0.95, movement: 0.3, time: time, reportCount: count))
        }
        view.update(diagnostic: diagnostic, monitorStatus: "Motion sensor active", now: 3.5)
        XCTAssertTrue(texts(view).contains("Motion detected"))
        XCTAssertFalse(view.resetButton.isHidden)
        XCTAssertEqual(view.resetButton.title, "Test again")

        view.update(diagnostic: diagnostic, monitorStatus: "Motion sensor stopped reporting", now: 6)
        XCTAssertTrue(texts(view).contains("Sensor readings stopped"))
        XCTAssertTrue(view.retryButton.isHidden == false)
        XCTAssertTrue(view.resetButton.isHidden)
        XCTAssertFalse(texts(view).contains("Motion detected"))
        XCTAssertEqual(signalMeter(in: view)?.accessibilityValue() as? String, "No live readings")
    }

    func testNativeDisclosureExposesAndHidesDetailedSensorDiagnostics() {
        let view = MotionSensorTestView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
        var diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        for i in 0...5 {
            diagnostic.receive(MotionSensorReading(x: 0.1, y: 0, z: 0.99, movement: 0.02, time: Double(i) / 10, reportCount: UInt64(i + 1)))
        }
        view.update(diagnostic: diagnostic, monitorStatus: "SPU accelerometer active", now: 0.5)
        XCTAssertFalse(texts(view).contains(where: { $0.contains("Motion RMS / peak") }))

        view.setDetailsExpanded(true)
        XCTAssertTrue(texts(view).contains(where: { $0.contains("Motion RMS / peak") }))
        XCTAssertTrue(texts(view).contains(where: { $0.contains("SPU accelerometer active") }))
        XCTAssertTrue(texts(view).contains(where: { $0.contains("reports/s") }))
        XCTAssertEqual(view.detailsButton.state, .on)

        view.setDetailsExpanded(false)
        XCTAssertFalse(texts(view).contains(where: { $0.contains("Motion RMS / peak") }))
        XCTAssertEqual(view.detailsButton.state, .off)
    }

    func testEnabledProtectionCopyPromisesResumeOnlyOnClose() {
        let view = MotionSensorTestView(
            frame: NSRect(x: 0, y: 0, width: 620, height: 500),
            protectionWasEnabled: true
        )
        let diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        view.update(diagnostic: diagnostic, monitorStatus: "Checking motion sensor…", now: 0)

        XCTAssertTrue(texts(view).contains(where: { $0.contains("protection resumes when you close") }))
        XCTAssertFalse(texts(view).contains(where: { $0.contains("remain off when you close") }))
    }

    func testTerminalSensorFailuresOfferRetryAndPreserveBackendDetails() {
        let view = MotionSensorTestView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
        let diagnostic = MotionSensorDiagnostic(sensitivity: 0.5)
        let failures = [
            "SPU accelerometer activation failed: report interval write failed",
            "No built-in SPU accelerometer found",
            "SPU accelerometer could not be opened (IOKit 0xe00002c5)",
            "SPU accelerometer opened but has not reported",
            "SPU accelerometer topology is unsupported: expected one driver",
            "Found 2 matching SPU accelerometers"
        ]

        for failure in failures {
            view.update(diagnostic: diagnostic, monitorStatus: failure, now: 0)
            let visible = texts(view)
            XCTAssertTrue(visible.contains("Sensor unavailable"), failure)
            XCTAssertTrue(visible.contains(where: { $0.contains("This Mac isn’t sending usable sensor readings") }), failure)
            XCTAssertTrue(visible.contains(where: { $0.contains("camera movement in Alarm mode") }), failure)
            XCTAssertFalse(view.retryButton.isHidden, failure)
            XCTAssertTrue(view.resetButton.isHidden, failure)
        }

        view.update(diagnostic: diagnostic, monitorStatus: failures[0], now: 0)
        view.setDetailsExpanded(true)
        XCTAssertTrue(texts(view).contains(where: { $0.contains(failures[0]) }))
    }

    func testSleepPauseExplainsResumeOnWakeWithoutOfferingRetry() {
        let view = MotionSensorTestView(frame: NSRect(x: 0, y: 0, width: 620, height: 500))
        view.update(
            diagnostic: MotionSensorDiagnostic(sensitivity: 0.5),
            monitorStatus: "Sensor test paused while the Mac sleeps",
            now: 0
        )

        let visible = texts(view)
        XCTAssertTrue(visible.contains("Sensor test paused"))
        XCTAssertTrue(visible.contains("It will resume when this Mac wakes."))
        XCTAssertTrue(view.retryButton.isHidden)
        XCTAssertTrue(view.resetButton.isHidden)
    }

    private func signalMeter(in view: NSView) -> NSView? {
        if view.accessibilityLabel() == "Live movement and tilt signal" { return view }
        return view.subviews.compactMap { signalMeter(in: $0) }.first
    }

    private func texts(_ view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        if let field = view as? NSTextField { return [field.stringValue] }
        if let button = view as? NSButton { return [button.title] }
        return view.subviews.flatMap(texts)
    }
}
