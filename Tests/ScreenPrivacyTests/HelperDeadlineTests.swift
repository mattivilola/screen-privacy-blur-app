import XCTest
@testable import ScreenPrivacy

@MainActor
final class HelperDeadlineTests: XCTestCase {
    func testAcceptedRequestWithNoReplyTimesOutAndInvalidates() async {
        var invalidated = false
        do {
            let _: Bool = try await boundedHelperReply(timeout: .milliseconds(10), onTimeout: { invalidated = true }) { _ in }
            XCTFail("An unresponsive helper must not hang disarm")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertTrue(invalidated)
    }
    func testReplyWinsOnceAndCancelsTimeout() async throws {
        var invalidated = false
        let result: Bool = try await boundedHelperReply(timeout: .milliseconds(10), onTimeout: { invalidated = true }) { reply in
            reply(.success(true)); reply(.success(false))
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(result); XCTAssertFalse(invalidated)
    }
}
