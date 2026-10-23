import Foundation
import XCTest
@testable import MotionSensorCore

final class SPUReportBufferTests: XCTestCase {
    func testAcceptsKnown22ByteReportAndCountsIt() {
        let buffer = makeBuffer(now: 100, time: { TimeInterval($0) })
        let bytes = [UInt8](repeating: 0xA5, count: 22)

        send(bytes, timestamp: 99, to: buffer)

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.latest?.rawReport, Data(bytes))
        XCTAssertEqual(snapshot.latest?.captureTime, 99)
        XCTAssertEqual(snapshot.latest?.sequence, 1)
    }

    func testIgnoresWrongReportLengths() {
        let buffer = makeBuffer(now: 100, time: { TimeInterval($0) })

        send([UInt8](repeating: 1, count: 21), timestamp: 99, to: buffer)
        send([UInt8](repeating: 1, count: 23), timestamp: 100, to: buffer)

        XCTAssertEqual(buffer.snapshot().count, 0)
        XCTAssertNil(buffer.snapshot().latest)
    }

    func testIgnoresDuplicateAndNonincreasingTimestamps() {
        let buffer = makeBuffer(now: 101.2) { 100 + TimeInterval($0) / 1_000 }
        let bytes = [UInt8](repeating: 2, count: 22)

        send(bytes, timestamp: 100, to: buffer)
        send(bytes, timestamp: 100, to: buffer)
        send(bytes, timestamp: 99, to: buffer)
        send(bytes, timestamp: 101, to: buffer)

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.latest?.sequence, 2)
        XCTAssertEqual(snapshot.latest?.captureTime, 100.101)
    }

    func testIgnoresStaleAndFutureTimestampsWithoutCountingThem() {
        let buffer = makeBuffer(now: 10) { timestamp in
            switch timestamp {
            case 1: 8.49 // 1.51 seconds old
            case 2: 10.01 // future relative to the injected clock
            default: 10
            }
        }
        let bytes = [UInt8](repeating: 3, count: 22)

        send(bytes, timestamp: 1, to: buffer)
        XCTAssertEqual(buffer.snapshot().count, 0)
        send(bytes, timestamp: 2, to: buffer)
        XCTAssertEqual(buffer.snapshot().count, 0)
        send(bytes, timestamp: 3, to: buffer)

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.latest?.captureTime, 10)
    }

    func testIgnoresCallbackAfterDeactivation() {
        let buffer = makeBuffer(now: 100, time: { TimeInterval($0) })
        let bytes = [UInt8](repeating: 4, count: 22)
        send(bytes, timestamp: 99, to: buffer)
        buffer.deactivate(clear: false)

        send(bytes, timestamp: 100, to: buffer)

        let snapshot = buffer.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.latest?.sequence, 1)
        XCTAssertEqual(snapshot.latest?.captureTime, 99)
    }

    private func makeBuffer(
        now: TimeInterval,
        time: @escaping @Sendable (UInt64) -> TimeInterval
    ) -> SPUReportBuffer {
        SPUReportBuffer(onReport: nil, currentUptime: { now }, secondsFromMachTimestamp: time)
    }

    private func send(_ bytes: [UInt8], timestamp: UInt64, to buffer: SPUReportBuffer) {
        bytes.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            buffer.accept(baseAddress, length: pointer.count, machTimestamp: timestamp)
        }
    }
}
