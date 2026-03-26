import XCTest
@testable import PulseType

final class MagicianCommandSanitizerTests: XCTestCase {
    func testSanitizeCollapsesRepeatedDirectionTokens() {
        let result = MagicianCommandSanitizer.sanitize("左左左 移动到行首")

        XCTAssertEqual(result.text, "左 移动到行首")
        XCTAssertTrue(result.appliedSkills.isEmpty)
    }

    func testSanitizeCollapsesRepeatedModifierWordsCaseInsensitively() {
        let result = MagicianCommandSanitizer.sanitize("shift SHIFT shift + k")

        XCTAssertEqual(result.text, "shift + k")
    }

    func testSanitizeNormalizesWhitespace() {
        let result = MagicianCommandSanitizer.sanitize("  右   右   option   option  ")

        XCTAssertEqual(result.text, "右 option")
    }
}
