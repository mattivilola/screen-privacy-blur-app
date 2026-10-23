import XCTest
@testable import AttentionCore

final class PhysicalMotionPolicyTests: XCTestCase {
    func testPhysicalThresholdsHaveSeparateLogarithmicUnits() {
        XCTAssertEqual(PhysicalMotionPolicy.accelerationThreshold(sensitivity: 0), 0.20, accuracy: 0.0001)
        XCTAssertEqual(PhysicalMotionPolicy.accelerationThreshold(sensitivity: 0.5), 0.0632456, accuracy: 0.0001)
        XCTAssertEqual(PhysicalMotionPolicy.accelerationThreshold(sensitivity: 1), 0.020, accuracy: 0.0001)
        XCTAssertEqual(PhysicalMotionPolicy.tiltThreshold(sensitivity: 0.5), 10, accuracy: 0.001)
        XCTAssertEqual(PhysicalMotionPolicy.tiltThreshold(sensitivity: 1), 5, accuracy: 0.001)
    }

    func testNativeRateNoiseAndBriefBumpDoNotTriggerButCarryingDoes() {
        XCTAssertFalse(simulate { time in (0.004 * sin(time * 240), 0, 1) }.triggered)
        // A sharp 10 ms bump is averaged over 250 ms and must not sound the alarm.
        XCTAssertFalse(simulate { time in (time >= 2 && time < 2.01 ? 0.5 : 0, 0, 1) }.triggered)
        let carry = simulate { time in (time >= 2 ? 0.20 * sin((time - 2) * 2 * .pi * 4) : 0, 0, 1) }
        XCTAssertTrue(carry.triggered)
        XCTAssertEqual(carry.reason, "sustained acceleration")
    }

    func testSlowTiltUsesFrozenReferenceAfterDynamicAccelerationSettles() {
        let result = simulate(duration: 7) { time in
            let angle = min(max(time - 2, 0) / 4, 1) * 15 * Double.pi / 180
            return (sin(angle), 0, cos(angle))
        }
        XCTAssertTrue(result.triggered)
        XCTAssertEqual(result.reason, "sustained tilt")
    }

    func testGapsAndBelowThresholdReadingsClearCandidateEvidence() {
        var policy = PhysicalMotionPolicy()
        for i in 0...30 { _ = policy.receive(sample(Double(i) * 0.05), armed: false, sensitivity: 0.5) }
        XCTAssertTrue(policy.isCalibrated)
        for time in [1.55, 1.6, 1.65] { XCTAssertFalse(policy.receive(sample(time, rms: 0.2), armed: true, sensitivity: 0.5)) }
        XCTAssertFalse(policy.receive(sample(1.7), armed: true, sensitivity: 0.5))
        XCTAssertFalse(policy.receive(sample(1.75, rms: 0.2), armed: true, sensitivity: 0.5))
        XCTAssertFalse(policy.receive(sample(2.1, rms: 0.2), armed: true, sensitivity: 0.5))
        XCTAssertFalse(policy.isCalibrated)
        XCTAssertFalse(policy.isReady(at: 4))
    }

    func testPhysicalPrimaryIgnoresMovingCameraAndFailoverRequiresNewEvidence() {
        var alarm = AlarmState(); alarm.countdown = 3; alarm.enable()
        alarm.observe(watching: true, at: 0)
        for i in 0...61 {
            let time = Double(i) * 0.05
            alarm.receiveSensor(sample(time))
            alarm.observe(watching: false, cameraMotion: 1, at: time)
        }
        XCTAssertEqual(alarm.phase, .armed)
        XCTAssertTrue(alarm.usesPhysicalPrimary(at: 3.06))
        alarm.motion(1, source: "camera", at: 3.1)
        alarm.motion(1, source: "camera", at: 3.5)
        XCTAssertEqual(alarm.phase, .armed)
        alarm.motion(1, source: "camera", at: 5)
        XCTAssertEqual(alarm.phase, .armed)
        alarm.motion(1, source: "camera", at: 5.3)
        XCTAssertEqual(alarm.phase, .alarming)
    }

    func testDelayedCameraFramesCannotDemotePhysicalPrimaryOrClearItsHold() {
        var alarm = AlarmState(); alarm.countdown = 3; alarm.enable()
        alarm.observe(watching: true, at: 0)
        for i in 0...62 {
            let time = Double(i) * 0.05
            alarm.receiveSensor(sample(time))
            alarm.observe(watching: false, cameraMotion: 1, at: max(0, time - 0.1))
        }
        XCTAssertEqual(alarm.phase, .armed)
        for time in [3.15, 3.2, 3.25, 3.3, 3.35, 3.4, 3.45, 3.5, 3.55] {
            alarm.receiveSensor(sample(time, rms: 0.2))
            alarm.interrupt() // Camera-only interruptions must not repeatedly erase the physical hold.
            alarm.observe(watching: false, cameraMotion: 1, at: time - 0.1)
            alarm.motion(1, source: "camera", at: time - 0.1)
            XCTAssertTrue(alarm.usesPhysicalPrimary(at: time - 0.1))
        }
        XCTAssertEqual(alarm.phase, .alarming)
        XCTAssertEqual(alarm.physicalMotion.triggerReason, "sustained acceleration")
    }

    func testCameraInterruptionPreservesFrozenArmedReference() {
        var alarm = AlarmState(); alarm.countdown = 3; alarm.enable()
        alarm.observe(watching: true, at: 0)
        for i in 0...61 {
            let time = Double(i) * 0.05
            alarm.receiveSensor(sample(time)); alarm.observe(watching: false, at: time)
        }
        alarm.interrupt()
        XCTAssertEqual(alarm.phase, .armed)
        XCTAssertTrue(alarm.usesPhysicalPrimary(at: 3.1))
    }

    private func sample(_ time: Double, rms: Double = 0) -> MotionSensorReading {
        MotionSensorReading(x: 0, y: 0, z: 1, movement: rms, time: time,
                            reportCount: UInt64(time * 1000) + 1, rmsMovement: rms)
    }
    private func simulate(duration: Double = 5, axes: (Double) -> (Double, Double, Double)) -> (triggered: Bool, reason: String?) {
        var filter = MotionSensorFilter(), policy = PhysicalMotionPolicy()
        var lastDelivery = -1.0
        for i in 0...Int(duration * 800) {
            let time = Double(i) / 800
            let v = axes(time)
            let reading = filter.sample(x: v.0, y: v.1, z: v.2, at: time)!
            if time - lastDelivery >= 0.049 {
                lastDelivery = time
                if policy.receive(reading, armed: time >= 1.5, sensitivity: 0.5) { return (true, policy.triggerReason) }
            }
        }
        return (false, nil)
    }
}
