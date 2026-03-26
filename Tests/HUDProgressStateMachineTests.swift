import XCTest
@testable import PulseType

final class HUDProgressStateMachineTests: XCTestCase {
    func testTranscribingStartsFromBaselineAndCap() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(to: .transcribing)

        XCTAssertEqual(frame.progress, 0.12, accuracy: 0.0001)
        XCTAssertEqual(machine.cap, 0.46, accuracy: 0.0001)
        XCTAssertTrue(frame.visibility.keepVisible)

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "转写中")
    }

    func testPhaseJumpToInsertingRaisesProgressBaseline() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .transcribing)
        _ = machine.tick()

        let frame = machine.transition(to: .inserting)

        XCTAssertGreaterThanOrEqual(frame.progress, 0.78)
        XCTAssertEqual(machine.cap, 0.94, accuracy: 0.0001)
        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "写入中")
    }

    func testRewritingUsesMagicianFallbackTitle() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(to: .rewriting)

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "魔术先生执行")
    }

    func testIdleAfterBusyEntersCompletionAndSchedulesQuickHide() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .transcribing)
        _ = machine.transition(to: .inserting)

        let frame = machine.transition(to: .idle)

        XCTAssertEqual(frame.style, .completion)
        XCTAssertEqual(frame.progress, 1.0, accuracy: 0.0001)
        XCTAssertFalse(frame.visibility.keepVisible)
        XCTAssertEqual(frame.visibility.hideDelay, 0.26, accuracy: 0.0001)
        XCTAssertEqual(frame.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testCancelledAndErrorUseExpectedHideDurations() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .listening)

        let cancelled = machine.transition(to: .cancelled)
        XCTAssertEqual(cancelled.style, .cancelled)
        XCTAssertEqual(cancelled.visibility.hideDelay, 0.46, accuracy: 0.0001)
        XCTAssertEqual(cancelled.visibility.fadeDuration, 0.12, accuracy: 0.0001)

        let error = machine.transition(to: .error)
        XCTAssertEqual(error.style, .error)
        XCTAssertEqual(error.visibility.hideDelay, 0.90, accuracy: 0.0001)
        XCTAssertEqual(error.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testTickSmoothlyApproachesCapWithoutOvershoot() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .transcribing)

        let first = machine.progress
        let second = machine.tick()
        XCTAssertGreaterThan(second, first)

        for _ in 0..<200 {
            _ = machine.tick()
        }

        XCTAssertLessThanOrEqual(machine.progress, 0.46)
        XCTAssertEqual(machine.progress, 0.46, accuracy: 0.001)
    }

    func testMagicianTitleResolverUsesThinkingDuringTranscribing() {
        let title = StatusPulseHUDTitleResolver.processingTitle(
            phase: .transcribing,
            lane: .selectionRewrite,
            message: "正在用 OpenAI 转写。",
            defaultTitle: "转写中"
        )

        XCTAssertEqual(title, "魔术先生 · 思考中")
    }

    func testMagicianTitleResolverUsesTaskLabelDuringRewriting() {
        let title = StatusPulseHUDTitleResolver.processingTitle(
            phase: .rewriting,
            lane: .selectionRewrite,
            message: "魔术先生执行中：写入备忘录中。",
            defaultTitle: "魔术先生执行"
        )

        XCTAssertEqual(title, "魔术先生 · 写入备忘录中")
    }

    func testListeningTitleResolverKeepsNonMagicianLaneUnchanged() {
        XCTAssertEqual(
            StatusPulseHUDTitleResolver.listeningTitle(for: .directDictation),
            "语音输入"
        )
        XCTAssertEqual(
            StatusPulseHUDTitleResolver.listeningTitle(for: .selectionRewrite),
            "魔术先生 · 聆听中"
        )
    }

    func testCompletionMessageResolverRemovesAppNameAndPathDetails() {
        let title = StatusPulseHUDMessageResolver.completionTitle(
            for: "文本已写入 TextEdit（AX 直写路径）。"
        )

        XCTAssertEqual(title, "已写入")
        XCTAssertFalse(title.contains("TextEdit"))
        XCTAssertFalse(title.contains("AX"))
    }

    func testCompletionMessageResolverNormalizesMagicianSuccessMessages() {
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "已通过 mailto 打开邮件草稿。"),
            "邮件已起草，待你确认"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "邮件已发送"),
            "邮件已发送"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "已提交到备忘录快捷指令。"),
            "已写入备忘录"
        )
    }

    func testErrorMessageResolverRemovesAppNameAndImplementationDetails() {
        let title = StatusPulseHUDMessageResolver.errorTitle(
            for: "TextEdit 写回失败。AX 路径原因：目标控件失效。"
        )

        XCTAssertEqual(title, "写入失败")
        XCTAssertFalse(title.contains("TextEdit"))
        XCTAssertFalse(title.contains("AX"))
    }
}
