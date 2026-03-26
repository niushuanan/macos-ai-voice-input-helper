import XCTest
@testable import PulseType

final class BrainstormFallbackComposerTests: XCTestCase {
    func testSummaryUsesFirstNonEmptyLineAsLeadPoint() {
        let summary = BrainstormFallbackComposer.summary(
            for: "\nAI 输入体验改版\n先做 HUD 再做热键"
        )

        XCTAssertTrue(summary.contains("本次讨论核心为：AI 输入体验改版。"))
    }

    func testDialoguePrefixesLinesWhenSpeakerIsMissing() {
        let dialogue = BrainstormFallbackComposer.dialogue(
            for: "先确认目标\n然后拆任务"
        )

        XCTAssertEqual(dialogue, "A: 先确认目标\nB: 然后拆任务")
    }

    func testDialogueKeepsExistingSpeakerPrefix() {
        let dialogue = BrainstormFallbackComposer.dialogue(
            for: "PM：先定范围\nB：明天开始做"
        )

        XCTAssertEqual(dialogue, "PM:先定范围\nB:明天开始做")
    }

    func testDialogueFallsBackWhenTranscriptIsEmpty() {
        XCTAssertEqual(
            BrainstormFallbackComposer.dialogue(for: " \n "),
            "A: （暂无有效转写内容）"
        )
    }
}
