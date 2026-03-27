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

    func testDictationRawTextStripsASRControlMarkers() {
        let entry = makeEntry(
            mode: .dictation,
            inputText: "<|zh|><|SAD|><|Speech|><|woitn|>我们开始进行这个流程的构建",
            outputText: "我们开始进行这个流程的构建",
            status: .success
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.rawText(for: entry),
            "我们开始进行这个流程的构建"
        )
    }

    func testSelectionRewriteEntryUsesSingleTextOnly() {
        let entry = makeEntry(
            mode: .selectionRewrite,
            inputText: "选中文本",
            outputText: "改写结果",
            status: .success
        )

        XCTAssertEqual(MemoryEntryTextResolver.magicianPrimaryText(for: entry), "改写结果")
        XCTAssertEqual(MemoryEntryTextResolver.magicianSecondaryText(for: entry), "选中文本")
        XCTAssertNil(MemoryEntryTextResolver.magicianInstructionText(for: entry))
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: entry), "改写结果")
    }

    func testSelectionRewriteSecondaryTextStripsASRControlMarkers() {
        let entry = SessionHistoryEntry(
            mode: .selectionRewrite,
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            inputText: "<|zh|><|SAD|><|Speech|><|woitn|>我们先做这个流程",
            outputText: "已建立日程。",
            instructionText: "帮我建日程",
            magicianFeatureID: .createEvent,
            displayText: nil,
            status: .success
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.magicianSecondaryText(for: entry),
            "我们先做这个流程"
        )
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

    func testMagicianTextTransformEntrySeparatesResultSourceAndInstruction() {
        let entry = SessionHistoryEntry(
            mode: .selectionRewrite,
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            inputText: "你好，世界",
            outputText: "Hello, world",
            instructionText: "翻译成英文",
            magicianFeatureID: .textTransform,
            displayText: nil,
            status: .success
        )

        XCTAssertEqual(MemoryEntryTextResolver.magicianPrimaryText(for: entry), "Hello, world")
        XCTAssertEqual(MemoryEntryTextResolver.magicianSecondaryText(for: entry), "你好，世界")
        XCTAssertEqual(MemoryEntryTextResolver.magicianInstructionText(for: entry), "翻译成英文")
    }

    func testMagicianToolEntryPrefersDisplayText() {
        let entry = SessionHistoryEntry(
            mode: .selectionRewrite,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            inputText: "周五 15:00 在 A 会议室评审 PRD",
            outputText: "周五 15:00 在 A 会议室评审 PRD",
            instructionText: "帮我写进备忘录",
            magicianFeatureID: .createNote,
            displayText: "已写入备忘录：周五 15:00 在 A 会议室评审 PRD",
            status: .success
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.magicianPrimaryText(for: entry),
            "已写入备忘录：周五 15:00 在 A 会议室评审 PRD"
        )
        XCTAssertEqual(
            MemoryEntryTextResolver.magicianSecondaryText(for: entry),
            "周五 15:00 在 A 会议室评审 PRD"
        )
        XCTAssertEqual(MemoryEntryTextResolver.magicianInstructionText(for: entry), "帮我写进备忘录")
    }

    func testMagicianPrimaryTextStripsLegacyInstructionPrefix() {
        let entry = SessionHistoryEntry(
            mode: .selectionRewrite,
            appName: "Notes",
            bundleID: "com.apple.Notes",
            inputText: "周五 15:00 在 A 会议室评审 PRD",
            outputText: "帮我写进备忘录。周五 15:00 在 A 会议室评审 PRD",
            instructionText: "帮我写进备忘录",
            magicianFeatureID: .createNote,
            displayText: "帮我写进备忘录。已写入备忘录：周五 15:00 在 A 会议室评审 PRD",
            status: .success
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.magicianPrimaryText(for: entry),
            "已写入备忘录：周五 15:00 在 A 会议室评审 PRD"
        )
        XCTAssertEqual(
            MemoryEntryTextResolver.magicianSecondaryText(for: entry),
            "周五 15:00 在 A 会议室评审 PRD"
        )
    }

    func testMagicianPrimaryTextStripsLegacyTemplateEnvelope() {
        let entry = SessionHistoryEntry(
            mode: .selectionRewrite,
            appName: "Calendar",
            bundleID: "com.apple.iCal",
            inputText: "周五 15:00 在 A 会议室评审 PRD",
            outputText: """
            评审 PRD

            来自 PulseType 魔术先生

            原文：
            周五 15:00 在 A 会议室评审 PRD

            指令：
            帮我建立日程
            """,
            instructionText: "帮我建立日程",
            magicianFeatureID: .createEvent,
            displayText: nil,
            status: .success
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.magicianPrimaryText(for: entry),
            "评审 PRD"
        )
    }

    func testMagicianFailedEntryShowsErrorSourceAndInstruction() {
        let entry = SessionHistoryEntry(
            mode: .selectionRewrite,
            appName: "WeChat",
            bundleID: "com.tencent.xinWeChat",
            inputText: "这周找个时间聊一下",
            outputText: nil,
            instructionText: "帮我建立日程",
            magicianFeatureID: .createEvent,
            displayText: nil,
            status: .failed,
            errorMessage: "未识别到明确时间，请补充具体日期和时间。"
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.magicianPrimaryText(for: entry),
            "未识别到明确时间，请补充具体日期和时间。"
        )
        XCTAssertEqual(MemoryEntryTextResolver.magicianSecondaryText(for: entry), "这周找个时间聊一下")
        XCTAssertEqual(MemoryEntryTextResolver.magicianInstructionText(for: entry), "帮我建立日程")
    }

    func testBrainstormEntryUsesOutputThenInputFallback() {
        let successEntry = makeEntry(
            mode: .brainstorm,
            inputText: "原始讨论",
            outputText: "- 结构化结论",
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
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: successEntry), "- 结构化结论")
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: fallbackEntry), "原始讨论")

        XCTAssertEqual(MemoryEntryTextResolver.brainstormSummaryText(for: successEntry), "- 结构化结论")
        XCTAssertEqual(MemoryEntryTextResolver.brainstormRawText(for: successEntry), "原始讨论")
        XCTAssertNil(MemoryEntryTextResolver.brainstormDialogueText(for: successEntry))
    }

    func testBrainstormEntryUsesDialogueWhenSummaryMissing() {
        let entry = SessionHistoryEntry(
            mode: .brainstorm,
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            inputText: "原始讨论",
            outputText: nil,
            brainstormDialogueText: "A: 先做核心\nB: 同意",
            status: .success
        )

        XCTAssertEqual(
            MemoryEntryTextResolver.brainstormDialogueText(for: entry),
            "A: 先做核心\nB: 同意"
        )
        XCTAssertEqual(MemoryEntryTextResolver.defaultText(for: entry), "A: 先做核心\nB: 同意")
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
