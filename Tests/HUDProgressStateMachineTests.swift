import XCTest
@testable import PulseType

final class HUDProgressStateMachineTests: XCTestCase {
    func testTranscribingStartsFromHintAndCap() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )

        XCTAssertEqual(frame.progress, 0.18, accuracy: 0.0001)
        XCTAssertEqual(machine.cap, 0.42, accuracy: 0.0001)
        XCTAssertEqual(machine.targetProgress, 0.26, accuracy: 0.0001)
        XCTAssertTrue(frame.visibility.keepVisible)

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "转写中")
    }

    func testPhaseJumpToInsertingRaisesProgressBaseline() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )
        _ = machine.tick()

        let frame = machine.transition(
            to: .inserting,
            progressHint: SessionHUDProgressHint.inserting,
            message: "正在把文本写入 TextEdit。"
        )

        XCTAssertGreaterThanOrEqual(frame.progress, 0.90)
        XCTAssertEqual(machine.cap, 0.97, accuracy: 0.0001)
        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "写入中")
    }

    func testRewritingUsesMagicianFallbackTitle() {
        var machine = HUDProgressStateMachine()

        let frame = machine.transition(
            to: .rewriting,
            progressHint: SessionHUDProgressHint.textTransform,
            message: "魔术先生执行中：文字处理中。"
        )

        guard case let .processing(title) = frame.style else {
            return XCTFail("expected processing style")
        }
        XCTAssertEqual(title, "魔术先生执行")
    }

    func testIdleAfterBusyEntersCompletionAndSchedulesQuickHide() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )
        _ = machine.transition(
            to: .inserting,
            progressHint: SessionHUDProgressHint.inserting,
            message: "正在把文本写入 TextEdit。"
        )

        let frame = machine.transition(
            to: .idle,
            progressHint: SessionHUDProgressHint.done,
            message: "文本已写入。"
        )

        XCTAssertEqual(frame.style, .completion)
        XCTAssertEqual(frame.progress, 1.0, accuracy: 0.0001)
        XCTAssertFalse(frame.visibility.keepVisible)
        XCTAssertEqual(frame.visibility.hideDelay, 0.26, accuracy: 0.0001)
        XCTAssertEqual(frame.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testCancelledAndErrorUseExpectedHideDurations() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(to: .listening, progressHint: 0, message: "正在聆听。")

        let cancelled = machine.transition(to: .cancelled, progressHint: 0, message: "已取消。")
        XCTAssertEqual(cancelled.style, .cancelled)
        XCTAssertEqual(cancelled.visibility.hideDelay, 0.46, accuracy: 0.0001)
        XCTAssertEqual(cancelled.visibility.fadeDuration, 0.12, accuracy: 0.0001)

        let error = machine.transition(to: .error, progressHint: 0, message: "执行失败。")
        XCTAssertEqual(error.style, .error)
        XCTAssertEqual(error.visibility.hideDelay, 0.90, accuracy: 0.0001)
        XCTAssertEqual(error.visibility.fadeDuration, 0.12, accuracy: 0.0001)
    }

    func testTickUsesHintBeforeSlowClimb() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .rewriting,
            progressHint: SessionHUDProgressHint.workflowPreview,
            message: "魔术先生执行中：流程预览：翻译成日语 -> 写入备忘录。"
        )

        let first = machine.progress
        let second = machine.tick()
        XCTAssertGreaterThan(second, first)
        XCTAssertLessThanOrEqual(second, machine.targetProgress)
        XCTAssertEqual(machine.targetProgress, 0.54, accuracy: 0.0001)
    }

    func testHigherHintInSamePhasePushesProgressForward() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .rewriting,
            progressHint: SessionHUDProgressHint.workflowPreview,
            message: "魔术先生执行中：流程预览：翻译成日语 -> 写入备忘录。"
        )
        _ = machine.tick()
        let before = machine.progress

        let frame = machine.transition(
            to: .rewriting,
            progressHint: SessionHUDProgressHint.workflowStep(index: 1, totalSteps: 2),
            message: "魔术先生执行中：第1/2步：翻译成日语中。"
        )

        XCTAssertGreaterThan(frame.progress, before)
        XCTAssertGreaterThan(machine.targetProgress, before)
    }

    func testTickContinuesClimbingAfterFastTargetUntilCeiling() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .rewriting,
            progressHint: SessionHUDProgressHint.workflowPreview,
            message: "魔术先生执行中：流程预览：翻译成日语 -> 写入备忘录。"
        )

        for _ in 0..<80 {
            _ = machine.tick()
        }
        let afterFastTarget = machine.progress

        for _ in 0..<20 {
            _ = machine.tick()
        }

        XCTAssertGreaterThan(machine.progress, afterFastTarget)
        XCTAssertLessThanOrEqual(machine.progress, machine.cap)
    }

    func testTickNeverExceedsCeiling() {
        var machine = HUDProgressStateMachine()
        _ = machine.transition(
            to: .transcribing,
            progressHint: SessionHUDProgressHint.transcribing,
            message: "正在用 OpenAI 转写。"
        )

        for _ in 0..<400 {
            _ = machine.tick()
        }

        XCTAssertLessThanOrEqual(machine.progress, 0.42)
        XCTAssertEqual(machine.progress, 0.42, accuracy: 0.001)
    }

    func testMagicianTitleResolverUsesThinkingDuringTranscribing() {
        let title = StatusPulseHUDTitleResolver.processingTitle(
            phase: .transcribing,
            lane: .selectionRewrite,
            message: "正在用 OpenAI 转写。",
            defaultTitle: "转写中"
        )

        XCTAssertEqual(title, "思考中")
    }

    func testMagicianTitleResolverUsesTaskLabelDuringRewriting() {
        let title = StatusPulseHUDTitleResolver.processingTitle(
            phase: .rewriting,
            lane: .selectionRewrite,
            message: "魔术先生执行中：写入备忘录中。",
            defaultTitle: "魔术先生执行"
        )

        XCTAssertEqual(title, "写入备忘录中")
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
            "邮件窗口已打开，请你确认"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "邮件已发送"),
            "邮件已发出"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "邮件已填入，待你确认"),
            "邮件已填入，待你确认"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "邮件窗口已打开，请你确认"),
            "邮件窗口已打开，请你确认"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "已提交到备忘录快捷指令。"),
            "已写入备忘录"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "已开始播放：周杰伦 - 稻香"),
            "已开始播放"
        )
        XCTAssertEqual(
            StatusPulseHUDMessageResolver.completionTitle(for: "已暂停播放"),
            "已暂停播放"
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
