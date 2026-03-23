import XCTest
@testable import PulseType

final class MemoryEntryTextResolverTests: XCTestCase {
    func testDictationEntryHasPrimaryAndRawText() {
        let entry = makeEntry(
            mode: .dictation,
            inputText: "原始识别",
            outputText: "过滤后文本",
            status: .success
        )

        XCTAssertEqual(MemoryEntryTextResolver.primaryText(for: entry), "过滤后文本")
        XCTAssertEqual(MemoryEntryTextResolver.rawText(for: entry), "原始识别")
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: entry), "过滤后文本")
        XCTAssertEqual(MemoryEntryTextResolver.placeholder(for: entry), "过滤后文本")
    }

    func testDictationEntryWithoutPrimaryFallsBackToRawText() {
        let entry = makeEntry(
            mode: .dictation,
            inputText: "原始识别",
            outputText: nil,
            status: .failed
        )

        XCTAssertNil(MemoryEntryTextResolver.primaryText(for: entry))
        XCTAssertEqual(MemoryEntryTextResolver.rawText(for: entry), "原始识别")
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: entry), "原始识别")
    }

    func testSelectionRewriteEntryUsesSingleTextOnly() {
        let entry = makeEntry(
            mode: .selectionRewrite,
            inputText: "选中文本",
            outputText: "改写结果",
            status: .success
        )

        XCTAssertNil(MemoryEntryTextResolver.primaryText(for: entry))
        XCTAssertNil(MemoryEntryTextResolver.rawText(for: entry))
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: entry), "改写结果")
    }

    func testPlaceholderUsesErrorMessageWhenNoText() {
        let entry = makeEntry(
            mode: .selectionRewrite,
            inputText: "",
            outputText: nil,
            status: .failed,
            errorMessage: "模型请求失败"
        )

        XCTAssertEqual(MemoryEntryTextResolver.placeholder(for: entry), "模型请求失败")
    }

    func testBrainstormEntryUsesOutputThenInputFallback() {
        let successEntry = makeEntry(
            mode: .brainstorm,
            inputText: "原始讨论",
            outputText: "结构化结论",
            status: .success
        )
        let fallbackEntry = makeEntry(
            mode: .brainstorm,
            inputText: "原始讨论",
            outputText: nil,
            status: .failed
        )

        XCTAssertNil(MemoryEntryTextResolver.primaryText(for: successEntry))
        XCTAssertNil(MemoryEntryTextResolver.rawText(for: successEntry))
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: successEntry), "结构化结论")
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: fallbackEntry), "原始讨论")
    }

    private func makeEntry(
        mode: SessionHistoryMode,
        inputText: String,
        outputText: String?,
        status: SessionHistoryStatus,
        errorMessage: String? = nil
    ) -> SessionHistoryEntry {
        SessionHistoryEntry(
            mode: mode,
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            inputText: inputText,
            outputText: outputText,
            status: status,
            errorMessage: errorMessage
        )
    }
}
