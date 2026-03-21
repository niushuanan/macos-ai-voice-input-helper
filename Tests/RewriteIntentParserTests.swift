import XCTest
@testable import PulseType

final class RewriteIntentParserTests: XCTestCase {
    private let parser = RewriteIntentParser()

    func testTranslateIntentDetectsJapanese() throws {
        let intent = try parser.parse(instruction: "请翻译成日语")

        switch intent.action {
        case let .translate(targetLanguage):
            XCTAssertEqual(targetLanguage, "Japanese")
        default:
            XCTFail("Expected translate action.")
        }
    }

    func testGenericPolishRespectsStructuredSceneBias() throws {
        let intent = try parser.parse(
            instruction: "润色一下",
            defaultOutputBias: .structured
        )

        switch intent.action {
        case .structure:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected structure action for structured scene bias.")
        }
    }

    func testEmptyInstructionThrows() {
        XCTAssertThrowsError(try parser.parse(instruction: "   ")) { error in
            guard case RewriteProviderError.emptyInstruction = error else {
                XCTFail("Expected emptyInstruction error, got \(error)")
                return
            }
        }
    }
}
