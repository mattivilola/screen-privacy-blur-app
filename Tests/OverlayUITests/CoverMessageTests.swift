import XCTest
@testable import OverlayUI

final class CoverMessageTests: XCTestCase {
    func testNormalizedPreservesComposedFamilyEmojiWithinCharacterLimit() {
        let family = "👨‍👩‍👧‍👦"
        let input = String(repeating: family, count: CoverMessage.maximumCharacters + 1)

        let result = CoverMessage.normalized(input)

        XCTAssertEqual(result.count, CoverMessage.maximumCharacters)
        XCTAssertEqual(result, String(repeating: family, count: CoverMessage.maximumCharacters))
    }

    func testNormalizedCollapsesWhitespaceAndTrims() {
        XCTAssertEqual(CoverMessage.normalized("  Private\n\t screen   active  "), "Private screen active")
    }

    func testBlankMessageUsesDefaultDisplayText() {
        XCTAssertEqual(CoverMessage.normalized(" \n\t "), "")
        XCTAssertEqual(CoverMessage.displayText(" \n\t "), CoverMessage.defaultText)
        XCTAssertEqual(CoverMessage.displayText("  Focus mode  "), "Focus mode")
    }

    func testNormalizedLimitsToMaximumCharacters() {
        let input = String(repeating: "a", count: CoverMessage.maximumCharacters + 1)

        XCTAssertEqual(CoverMessage.normalized(input).count, CoverMessage.maximumCharacters)
    }
}
