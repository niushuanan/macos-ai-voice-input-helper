import Combine
import XCTest
@testable import PulseType

@MainActor
final class InteractionCoordinatorTests: XCTestCase {
    func testWakeKeyStartsAndSecondWakeStopsRecording() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)

        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.audioCapture.startCallCount, 1)
        XCTAssertTrue(fixture.audioCapture.isRecording)

        fixture.coordinator.handleWakeInput(context: .dictation)

        XCTAssertEqual(fixture.audioCapture.stopCallCount, 1)
        XCTAssertFalse(fixture.audioCapture.isRecording)
        XCTAssertNotEqual(fixture.sessionStore.phase, .listening)
    }

    func testCancelKeyInterruptsSessionAndCreatesCancelledHistory() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleCancelInput()

        XCTAssertEqual(fixture.sessionStore.phase, .cancelled)
        XCTAssertEqual(fixture.audioCapture.cancelCallCount, 1)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .cancelled)
    }

    func testBrainstormIsBlockedDuringNormalDictationAndShowsSingleToastWithinCooldown() throws {
        let toastPresenter = ToastPresenter()
        let fixture = try makeFixture(toastPresenter: toastPresenter)
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)
        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.sessionStore.activeLane, .directDictation)

        fixture.coordinator.handleBrainstormInput()
        let firstToast = toastPresenter.message?.text
        XCTAssertEqual(firstToast, "当前是普通语音输入，脑暴双击已忽略。请先停止本次录音。")

        fixture.coordinator.handleBrainstormInput()
        XCTAssertEqual(toastPresenter.message?.text, firstToast)
        XCTAssertEqual(fixture.audioCapture.startCallCount, 1)
        XCTAssertTrue(fixture.audioCapture.isRecording)
    }

    func testBrainstormFlowWritesComposedContextAndHistory() async throws {
        let composer = FakeBrainstormContextComposer(
            result: .success(
                summaryText: """
                - 先完成核心链路验证。
                - 高级能力放到下一迭代。
                - 先保证闭环可用再扩展。
                """,
                dialogueText: """
                A: 先做核心链路
                B: 先别加复杂配置
                """
            )
        )
        let fixture = try makeFixture(
            brainstormContextComposer: composer,
            transcriptionText: "A：先做核心链路"
        )
        defer { fixture.cleanUp() }

        fixture.coordinator.handleBrainstormInput()
        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.sessionStore.activeLane, .brainstormDiscussion)

        fixture.coordinator.handleBrainstormInput()
        await waitForPipeline(using: fixture.sessionStore)

        let expectedSummary = """
        - 先完成核心链路验证。
        - 高级能力放到下一迭代。
        - 先保证闭环可用再扩展。
        """
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, expectedSummary)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.mode, .brainstorm)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.outputText, expectedSummary)
        XCTAssertEqual(
            fixture.localHistoryStore.entries.first?.brainstormDialogueText,
            """
            A: 先做核心链路
            B: 先别加复杂配置
            """
        )
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .success)
    }

    func testBrainstormFallsBackToTemplateWhenTranscriptEmpty() async throws {
        let composer = FakeBrainstormContextComposer(
            result: .success(summaryText: "不该被用到", dialogueText: "不该被用到")
        )
        let fixture = try makeFixture(
            brainstormContextComposer: composer,
            transcriptionText: "   "
        )
        defer { fixture.cleanUp() }

        fixture.coordinator.handleBrainstormInput()
        fixture.coordinator.handleBrainstormInput()
        await waitForPipeline(using: fixture.sessionStore)

        let written = fixture.textOutputCoordinator.lastRequest?.text ?? ""
        XCTAssertTrue(written.contains("先确认讨论目标与边界"))
        XCTAssertEqual(composer.callCount, 0)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.mode, .brainstorm)
    }

    func testBrainstormAppliesSpokenFilterBeforeComposeAndRecordsSkill() async throws {
        let composer = FakeBrainstormContextComposer(
            result: .success(
                summaryText: "- 先做验证。\n- 先保留最小范围。\n- 明确负责人。",
                dialogueText: "A: 先做验证"
            )
        )
        let fixture = try makeFixture(
            brainstormContextComposer: composer,
            transcriptionText: "嗯 先做验证"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .spokenFilter)
        fixture.skillRuleStore.setParameter("嗯", for: .spokenFilter)

        fixture.coordinator.handleBrainstormInput()
        fixture.coordinator.handleBrainstormInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(composer.lastRequest?.transcript, "先做验证")
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.appliedSkills, [.spokenFilter])
    }

    func testBrainstormIncludesSystemAndAppPromptAndRecordsAppliedSkills() async throws {
        let composer = FakeBrainstormContextComposer(
            result: .success(
                summaryText: "- 结论一。\n- 结论二。\n- 结论三。",
                dialogueText: "A: 内容"
            )
        )
        let fixture = try makeFixture(
            brainstormContextComposer: composer,
            transcriptionText: "先看一下这个需求"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("请更简洁。", for: .systemPrompt)
        fixture.skillRuleStore.setEnabled(true, for: .appPreferenceBoost)
        fixture.appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "优先输出可执行结论。"
        )

        fixture.coordinator.handleBrainstormInput()
        fixture.coordinator.handleBrainstormInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(composer.lastRequest?.userSystemPrompt, "请更简洁。")
        XCTAssertEqual(composer.lastRequest?.appPrompt, "优先输出可执行结论。")
        XCTAssertEqual(
            fixture.localHistoryStore.entries.first?.appliedSkills,
            [.appPreferenceBoost, .systemPrompt]
        )
    }

    func testBrainstormComposerFailureFallsBackWithoutModelSkills() async throws {
        let composer = FakeBrainstormContextComposer(
            result: .failure(RewriteProviderError.invalidGeneratedText)
        )
        let fixture = try makeFixture(
            brainstormContextComposer: composer,
            transcriptionText: "讨论一下核心链路"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("请更简洁。", for: .systemPrompt)
        fixture.skillRuleStore.setEnabled(true, for: .appPreferenceBoost)
        fixture.appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "优先输出可执行结论。"
        )

        fixture.coordinator.handleBrainstormInput()
        fixture.coordinator.handleBrainstormInput()
        await waitForPipeline(using: fixture.sessionStore)

        let history = try XCTUnwrap(fixture.localHistoryStore.entries.first)
        XCTAssertTrue((history.outputText ?? "").contains("- "))
        XCTAssertEqual(history.appliedSkills, [])
    }

    func testBrainstormAutoStopsAtDurationLimitOnlyOnce() async throws {
        let toastPresenter = ToastPresenter()
        let fixture = try makeFixture(
            brainstormDurationProfile: BrainstormDurationProfile(
                providerType: .localSenseVoice,
                modelName: "sensevoice-small",
                maxSeconds: 1,
                recommendedSeconds: 30,
                measuredAt: Date()
            ),
            toastPresenter: toastPresenter
        )
        defer { fixture.cleanUp() }

        fixture.coordinator.handleBrainstormInput()
        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.sessionStore.activeLane, .brainstormDiscussion)

        try? await Task.sleep(nanoseconds: 1_400_000_000)
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.audioCapture.stopCallCount, 1)
        XCTAssertEqual(toastPresenter.message?.text, "已到脑暴时长上限，已自动结束录音并开始整理。")
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.mode, .brainstorm)
    }

    func testInvalidResponseRetriesOnceAndThenFailsWithTraceID() async throws {
        let fixture = try makeFixture(
            transcriptionResponses: [
                .failure(.invalidResponse),
                .failure(.invalidResponse)
            ]
        )
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.transcriptionProvider.callCount, 2)
        XCTAssertEqual(fixture.sessionStore.phase, .error)
        XCTAssertTrue(fixture.sessionStore.statusMessage.contains("traceID:"))

        let logText = (try? String(contentsOf: fixture.speechPipelineLogURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("\"stage\":\"asr.retry\""))
        let failureCount = logText.components(separatedBy: "\"stage\":\"asr.attempt.failed\"").count - 1
        XCTAssertGreaterThanOrEqual(failureCount, 2)
    }

    func testWriteFailureIsLoggedAndMarkedAsFailedHistory() async throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.errorToThrow = TextOutputError.noEditableTarget
        let fixture = try makeFixture(textOutputCoordinator: textOutputCoordinator)
        defer { fixture.cleanUp() }

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .failed)
        let logText = (try? String(contentsOf: fixture.speechPipelineLogURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(logText.contains("\"stage\":\"write.failed\""))
    }

    func testDictationUsesPostProcessedTextWhenHeuristicRequiresTextProcessing() async throws {
        let postProcessor = FakeDictationPostProcessor(result: .success("整理后的听写"))
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: "<|zh|><|NEUTRAL|><|Speech|><|woitn|>请帮我整理这段文字"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "整理后的听写")
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.outputText, "整理后的听写")
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.appliedSkills, [.systemPrompt])
    }

    func testDictationFallsBackToLocalTextWhenPostProcessorFails() async throws {
        let rawTranscript = "<|zh|><|NEUTRAL|><|Speech|><|woitn|>请帮我整理这段文字"
        let postProcessor = FakeDictationPostProcessor(result: .failure(RewriteProviderError.invalidGeneratedText))
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: rawTranscript
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, rawTranscript)
        XCTAssertTrue(fixture.sessionStore.statusMessage.contains("已退回本地结果"))
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.outputText, rawTranscript)
    }

    func testDisabledAppPreferenceBoostDoesNotAutoEnterRewrite() throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = FocusedSelectionSnapshot(
            focusContext: FixedContextDetector().focusedAppContext(),
            selectedText: "selected"
        )
        let fixture = try makeFixture(textOutputCoordinator: textOutputCoordinator)
        defer { fixture.cleanUp() }

        fixture.appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "请更正式一些。"
        )
        fixture.skillRuleStore.setEnabled(false, for: .appPreferenceBoost)

        fixture.coordinator.handleWakeInput(context: .dictation)

        XCTAssertEqual(fixture.sessionStore.activeLane, .directDictation)
    }

    func testWakeTapKeepsDirectDictationEvenWhenMagicianEnabledAndSelectionExists() throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = FocusedSelectionSnapshot(
            focusContext: FixedContextDetector().focusedAppContext(),
            selectedText: "选中文本"
        )
        let fixture = try makeFixture(textOutputCoordinator: textOutputCoordinator)
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .textTransform)

        fixture.coordinator.handleWakeInput(context: .dictationTap)

        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.sessionStore.activeLane, .directDictation)
    }

    func testMagicianHoldEntersSelectionRewrite() throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = FocusedSelectionSnapshot(
            focusContext: FixedContextDetector().focusedAppContext(),
            selectedText: "选中文本"
        )
        let fixture = try makeFixture(textOutputCoordinator: textOutputCoordinator)
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .textTransform)

        fixture.coordinator.handleWakeInput(context: .magicianHold)

        XCTAssertEqual(fixture.sessionStore.phase, .listening)
        XCTAssertEqual(fixture.sessionStore.activeLane, .selectionRewrite)
    }

    func testSelectionRewriteRoutesToMagicianToolIntent() async throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = FocusedSelectionSnapshot(
            focusContext: FixedContextDetector().focusedAppContext(),
            selectedText: "OpenAI o3 mini"
        )
        let router = FakeMagicianIntentRouter(
            intent: MagicianIntent(
                intent: .createNote,
                confidence: 0.95,
                sourceText: "OpenAI o3 mini",
                params: MagicianIntentParams(
                    mode: nil,
                    targetLanguage: nil,
                    tone: nil,
                    title: nil,
                    startAt: nil,
                    endAt: nil,
                    location: nil,
                    noteBody: "OpenAI o3 mini",
                    mailTo: nil,
                    mailSubject: nil,
                    mailBody: nil
                )
            )
        )
        let toolExecutor = FakeMagicianToolExecutor()
        toolExecutor.result = .success(
            MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已写入备忘录。",
                outputText: "OpenAI o3 mini",
                fallbackUsed: false
            )
        )

        let fixture = try makeFixture(
            textOutputCoordinator: textOutputCoordinator,
            magicianIntentRouter: router,
            magicianToolExecutor: toolExecutor,
            transcriptionText: "帮我写进备忘录"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .createNote)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.sessionStore.phase, .idle)
        XCTAssertEqual(fixture.sessionStore.statusMessage, "已写入备忘录。")
        XCTAssertEqual(toolExecutor.callCount, 1)
        XCTAssertEqual(toolExecutor.lastIntent?.intent, .createNote)
        XCTAssertEqual(toolExecutor.lastExecutionContext?.selection?.selectedText, "OpenAI o3 mini")
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .success)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.outputText, "OpenAI o3 mini")
    }

    func testCancelDuringMagicianThinkingKeepsCancelledState() async throws {
        let router = DelayedFailingMagicianIntentRouter(
            delayNanoseconds: 180_000_000,
            error: MagicianError(
                code: .intentParseFailed,
                userMessage: "文本模型不可用。",
                debugMessage: nil,
                recoverAction: nil
            )
        )
        let fixture = try makeFixture(
            magicianIntentRouter: router,
            transcriptionText: "帮我写进备忘录"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .createNote)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        try? await Task.sleep(nanoseconds: 50_000_000)
        fixture.coordinator.handleCancelInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.sessionStore.phase, .cancelled)
        XCTAssertEqual(fixture.sessionStore.statusMessage, "本次会话已取消，目标应用内容未变化。")
        XCTAssertNil(fixture.sessionStore.errorMessage)
        XCTAssertEqual(fixture.localHistoryStore.entries.count, 1)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .cancelled)
        XCTAssertFalse(fixture.sessionStore.statusMessage.contains("文本模型不可用"))
    }

    func testMagicianToolIntentAllowsNoSelection() async throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = nil

        let router = FakeMagicianIntentRouter(
            intent: MagicianIntent(
                intent: .createNote,
                confidence: 0.81,
                sourceText: "",
                params: MagicianIntentParams(
                    mode: nil,
                    targetLanguage: nil,
                    tone: nil,
                    title: nil,
                    startAt: nil,
                    endAt: nil,
                    location: nil,
                    noteBody: "周五和产品开会",
                    mailTo: nil,
                    mailSubject: nil,
                    mailBody: nil
                )
            )
        )
        let toolExecutor = FakeMagicianToolExecutor()
        toolExecutor.result = .success(
            MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已写入备忘录。",
                outputText: "周五和产品开会",
                fallbackUsed: false
            )
        )

        let fixture = try makeFixture(
            textOutputCoordinator: textOutputCoordinator,
            magicianIntentRouter: router,
            magicianToolExecutor: toolExecutor,
            transcriptionText: "记一下周五和产品开会"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .createNote)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.sessionStore.phase, .idle)
        XCTAssertEqual(toolExecutor.callCount, 1)
        XCTAssertNil(toolExecutor.lastExecutionContext?.selection)
        XCTAssertEqual(
            toolExecutor.lastExecutionContext?.command,
            "记一下周五和产品开会"
        )
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .success)
    }

    func testMagicianASRRequestSkipsDictionaryInjection() async throws {
        let router = FakeMagicianIntentRouter(
            intent: MagicianIntent(
                intent: .createNote,
                confidence: 0.93,
                sourceText: "",
                params: MagicianIntentParams(
                    mode: nil,
                    targetLanguage: nil,
                    tone: nil,
                    title: nil,
                    startAt: nil,
                    endAt: nil,
                    location: nil,
                    noteBody: "OpenAI o3",
                    mailTo: nil,
                    mailSubject: nil,
                    mailBody: nil
                )
            )
        )
        let toolExecutor = FakeMagicianToolExecutor()
        toolExecutor.result = .success(
            MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已写入备忘录。",
                outputText: "OpenAI o3",
                historyDisplayText: "已写入备忘录：OpenAI o3",
                fallbackUsed: false
            )
        )

        let fixture = try makeFixture(
            magicianIntentRouter: router,
            magicianToolExecutor: toolExecutor,
            transcriptionText: "帮我记到备忘录"
        )
        defer { fixture.cleanUp() }

        fixture.dictionaryStore.save(rawText: "OpenAI\n词典热词")
        fixture.magicianFeatureToggleStore.setEnabled(true, for: .createNote)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.transcriptionProvider.lastRequest?.lane, .selectionRewrite)
        XCTAssertEqual(fixture.transcriptionProvider.lastRequest?.dictionaryTerms, [])
        XCTAssertEqual(fixture.transcriptionProvider.lastRequest?.dictionaryPromptHint, nil)
        XCTAssertEqual(fixture.transcriptionProvider.lastRequest?.dictionaryHotwordText, nil)
    }

    func testRemovedSearchCommandDoesNotRouteIntoOtherTool() async throws {
        let toolExecutor = FakeMagicianToolExecutor()
        let fixture = try makeFixture(
            magicianIntentRouter: HeuristicMagicianIntentRouter(),
            magicianToolExecutor: toolExecutor,
            transcriptionText: "帮我搜索一下"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .createNote)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.sessionStore.phase, .error)
        XCTAssertEqual(toolExecutor.callCount, 0)
        XCTAssertTrue(fixture.sessionStore.statusMessage.contains("快速搜索已下线"))
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .failed)
        XCTAssertTrue((fixture.localHistoryStore.entries.first?.errorMessage ?? "").contains("快速搜索已下线"))
    }

    func testMagicianClipboardFallbackSelectionIsLockedIntoExecutionContext() async throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = nil
        textOutputCoordinator.capturedSelectionSnapshot = FocusedSelectionSnapshot(
            focusContext: FocusedAppContext(
                appName: "WeChat",
                bundleID: "com.tencent.xinWeChat",
                focusedRole: nil,
                hasEditableTarget: false,
                strategyHint: "copy-fallback"
            ),
            selectedText: "4月1日 14:30 在上海办公室和产品团队开路标会"
        )

        let router = FakeMagicianIntentRouter(
            intent: MagicianIntent(
                intent: .createEvent,
                confidence: 0.95,
                sourceText: "4月1日 14:30 在上海办公室和产品团队开路标会",
                params: MagicianIntentParams(
                    mode: nil,
                    targetLanguage: nil,
                    tone: nil,
                    title: "产品团队路标会",
                    startAt: "2026-04-01T14:30:00+08:00",
                    endAt: "2026-04-01T15:30:00+08:00",
                    location: "上海办公室",
                    noteBody: nil,
                    mailTo: nil,
                    mailSubject: nil,
                    mailBody: nil
                )
            )
        )
        let toolExecutor = FakeMagicianToolExecutor()
        toolExecutor.result = .success(
            MagicianExecutionResult(
                intent: .createEvent,
                userMessage: "已建日程：产品团队路标会",
                outputText: "产品团队路标会",
                historyDisplayText: "已建日程：产品团队路标会",
                fallbackUsed: false
            )
        )

        let fixture = try makeFixture(
            textOutputCoordinator: textOutputCoordinator,
            magicianIntentRouter: router,
            magicianToolExecutor: toolExecutor,
            transcriptionText: "帮我建立日程"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .createEvent)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(textOutputCoordinator.captureSelectionCallCount, 1)
        XCTAssertEqual(
            toolExecutor.lastExecutionContext?.selection?.selectedText,
            "4月1日 14:30 在上海办公室和产品团队开路标会"
        )
        XCTAssertEqual(
            fixture.localHistoryStore.entries.first?.inputText,
            "4月1日 14:30 在上海办公室和产品团队开路标会"
        )
        XCTAssertEqual(
            fixture.localHistoryStore.entries.first?.instructionText,
            "帮我建立日程"
        )
    }

    func testMagicianTextTransformFailsWithoutSelection() async throws {
        let textOutputCoordinator = FakeTextOutputCoordinator()
        textOutputCoordinator.selectionSnapshot = nil
        let router = FakeMagicianIntentRouter(
            intent: MagicianIntent(
                intent: .textTransform,
                confidence: 0.9,
                sourceText: "",
                params: MagicianIntentParams(
                    mode: .polish,
                    targetLanguage: nil,
                    tone: nil,
                    title: nil,
                    startAt: nil,
                    endAt: nil,
                    location: nil,
                    noteBody: nil,
                    mailTo: nil,
                    mailSubject: nil,
                    mailBody: nil
                )
            )
        )
        let toolExecutor = FakeMagicianToolExecutor()

        let fixture = try makeFixture(
            textOutputCoordinator: textOutputCoordinator,
            magicianIntentRouter: router,
            magicianToolExecutor: toolExecutor,
            transcriptionText: "帮我润色一下"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .textTransform)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.sessionStore.phase, .error)
        XCTAssertTrue(fixture.sessionStore.statusMessage.contains("文字处理需要先选中一段文本"))
        XCTAssertEqual(toolExecutor.callCount, 0)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .failed)
    }

    func testDictationSkipsPostProcessWhenSystemPromptIsEmpty() async throws {
        let postProcessor = CountingDictationPostProcessor(outputText: "不该被用到")
        let fixture = try makeFixture(dictationPostProcessor: postProcessor)
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("   ", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(postProcessor.callCount, 0)
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "hello world")
    }

    func testDictationPostProcessIncludesAppPromptWhenMatched() async throws {
        let postProcessor = CapturingDictationPostProcessor(outputText: "处理后文本")
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: "<|zh|><|NEUTRAL|><|Speech|><|woitn|>应用提示词测试"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .appPreferenceBoost)
        fixture.appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "请优先输出清晰结论。"
        )

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(postProcessor.lastRequest?.appPrompt, "请优先输出清晰结论。")
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "处理后文本")
    }

    func testDisabledAppPreferenceBoostRemovesAppPromptFromPostProcess() async throws {
        let postProcessor = CapturingDictationPostProcessor(outputText: "处理后文本")
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: "<|zh|><|NEUTRAL|><|Speech|><|woitn|>应用提示词测试"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("保留重点。", for: .systemPrompt)
        fixture.appScenePolicyStore.upsertPolicy(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            appPrompt: "请优先输出清晰结论。"
        )
        fixture.skillRuleStore.setEnabled(false, for: .appPreferenceBoost)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertNil(postProcessor.lastRequest?.appPrompt)
        XCTAssertEqual(postProcessor.lastRequest?.userSystemPrompt, "保留重点。")
    }

    func testDictationSkipsTextProcessingForShortCleanTranscript() async throws {
        let postProcessor = CountingDictationPostProcessor(outputText: "不该被用到")
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: "hello"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(postProcessor.callCount, 0)
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "hello")
    }

    func testDictationUsesTextProcessingForCleanTranscriptLongerThanTenCharacters() async throws {
        let postProcessor = CountingDictationPostProcessor(outputText: "模型已处理")
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: "abcdefghijk"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(postProcessor.callCount, 1)
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "模型已处理")
    }

    func testDictationUsesTextProcessingForShortDirtyTranscript() async throws {
        let postProcessor = CountingDictationPostProcessor(outputText: "模型已处理")
        let fixture = try makeFixture(
            dictationPostProcessor: postProcessor,
            transcriptionText: "你好。。"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(postProcessor.callCount, 1)
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "模型已处理")
    }

    func testSavedDictionaryIsInjectedIntoNextASRRequestImmediately() async throws {
        let fixture = try makeFixture(transcriptionText: "词典测试")
        defer { fixture.cleanUp() }

        fixture.dictionaryStore.save(rawText: "OpenAI\nDeepSeek\nDeepSeek\nsemantic cache")

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        let request = try XCTUnwrap(fixture.transcriptionProvider.lastRequest)
        XCTAssertEqual(request.dictionaryTerms, ["OpenAI", "DeepSeek", "semantic cache"])
        XCTAssertNotNil(request.dictionaryPromptHint)
        XCTAssertTrue(request.dictionaryPromptHint?.contains("OpenAI") == true)
        XCTAssertEqual(request.dictionaryHotwordText, "OpenAI\nDeepSeek\nsemantic cache")
    }

    private func makeFixture(
        textOutputCoordinator: FakeTextOutputCoordinator? = nil,
        dictationPostProcessor: DictationPostProcessor = FakeDictationPostProcessor(result: .success("hello world")),
        brainstormContextComposer: BrainstormContextComposer = FakeBrainstormContextComposer(
            result: .success(
                summaryText: "- 默认结论一。\n- 默认结论二。\n- 默认结论三。",
                dialogueText: "A: 默认对话"
            )
        ),
        magicianIntentRouter: (any MagicianIntentRouting)? = nil,
        magicianToolExecutor: (any MagicianToolExecuting)? = nil,
        transcriptionText: String = "hello world",
        transcriptionResponses: [Result<String, SpeechTranscriptionError>]? = nil,
        brainstormDurationProfile: BrainstormDurationProfile? = nil,
        toastPresenter: ToastPresenter? = nil
    ) throws -> InteractionFixture {
        let defaultsSuiteName = "InteractionCoordinatorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw NSError(domain: "InteractionCoordinatorTests", code: 1)
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let diagnosticsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)

        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-clip-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Data([0x01, 0x02]).write(to: clipURL)

        let sessionStore = SessionStore()
        let permissionsCenter = PermissionsCenter(
            defaults: defaults,
            microphoneStateResolver: { .granted },
            accessibilityStateResolver: { .granted }
        )
        let audioCapture = FakeAudioCaptureService(
            clip: RecordedAudioClip(
                id: UUID(),
                fileURL: clipURL,
                duration: 0.8,
                sampleRate: 44_100,
                createdAt: Date()
            )
        )
        let credentialStore = MemoryCredentialStoreForInteractionTests(
            storage: ["text.primary": "sk-test-000000"]
        )
        let providerSettingsStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: credentialStore
        )
        providerSettingsStore.updateASRProviderType(.localSenseVoice)
        let localHistoryStore = LocalHistoryStore(historyDirectory: historyDirectory)
        let brainstormDurationProfileStore = BrainstormDurationProfileStore(historyDirectory: historyDirectory)
        if let brainstormDurationProfile {
            brainstormDurationProfileStore.upsert(brainstormDurationProfile)
        }
        let speechPipelineLogger = SpeechPipelineLogger(diagnosticsDirectory: diagnosticsDirectory)
        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.interaction.tests")
        let magicianFeatureToggleStore = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.features.interaction.tests"
        )
        let transcriptionProvider: FakeTranscriptionProvider
        if let transcriptionResponses {
            transcriptionProvider = FakeTranscriptionProvider(scriptedResponses: transcriptionResponses)
        } else {
            transcriptionProvider = FakeTranscriptionProvider(transcript: transcriptionText)
        }
        let resolvedTextOutputCoordinator = textOutputCoordinator ?? FakeTextOutputCoordinator()
        let dictionaryStore = ASRDictionaryStore(
            defaults: defaults,
            storageKey: "asr.dictionary.interaction.tests"
        )
        let resolvedToastPresenter = toastPresenter

        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: permissionsCenter,
            audioCaptureService: audioCapture,
            providerSettingsStore: providerSettingsStore,
            providerRegistry: SpeechProviderRegistry(providers: [transcriptionProvider]),
            rewriteProviderRegistry: RewriteProviderRegistry(providers: []),
            textOutputCoordinator: resolvedTextOutputCoordinator,
            contextDetector: FixedContextDetector(),
            appScenePolicyStore: appScenePolicyStore,
            localHistoryStore: localHistoryStore,
            brainstormDurationProfileStore: brainstormDurationProfileStore,
            speechPipelineLogger: speechPipelineLogger,
            skillRuleStore: skillRuleStore,
            asrDictionaryStore: dictionaryStore,
            magicianFeatureToggleStore: magicianFeatureToggleStore,
            magicianIntentRouter: magicianIntentRouter,
            magicianToolExecutor: magicianToolExecutor ?? MagicianToolExecutor(),
            toastPresenter: resolvedToastPresenter,
            dictationPostProcessor: dictationPostProcessor,
            brainstormContextComposer: brainstormContextComposer
        )

        return InteractionFixture(
            coordinator: coordinator,
            sessionStore: sessionStore,
            audioCapture: audioCapture,
            textOutputCoordinator: resolvedTextOutputCoordinator,
            localHistoryStore: localHistoryStore,
            brainstormDurationProfileStore: brainstormDurationProfileStore,
            skillRuleStore: skillRuleStore,
            magicianFeatureToggleStore: magicianFeatureToggleStore,
            appScenePolicyStore: appScenePolicyStore,
            transcriptionProvider: transcriptionProvider,
            dictionaryStore: dictionaryStore,
            speechPipelineLogURL: diagnosticsDirectory.appendingPathComponent("speech-pipeline.log", isDirectory: false),
            cleanUp: {
                try? FileManager.default.removeItem(at: historyDirectory)
                try? FileManager.default.removeItem(at: diagnosticsDirectory)
                try? FileManager.default.removeItem(at: clipURL)
                defaults.removePersistentDomain(forName: defaultsSuiteName)
            }
        )
    }

    private func waitForPipeline(
        using sessionStore: SessionStore,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if sessionStore.phase == .idle || sessionStore.phase == .error || sessionStore.phase == .cancelled {
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}

private struct InteractionFixture {
    let coordinator: InteractionCoordinator
    let sessionStore: SessionStore
    let audioCapture: FakeAudioCaptureService
    let textOutputCoordinator: FakeTextOutputCoordinator
    let localHistoryStore: LocalHistoryStore
    let brainstormDurationProfileStore: BrainstormDurationProfileStore
    let skillRuleStore: SkillRuleStore
    let magicianFeatureToggleStore: MagicianFeatureToggleStore
    let appScenePolicyStore: AppScenePolicyStore
    let transcriptionProvider: FakeTranscriptionProvider
    let dictionaryStore: ASRDictionaryStore
    let speechPipelineLogURL: URL
    let cleanUp: () -> Void
}

@MainActor
private final class FakeAudioCaptureService: AudioCaptureService {
    let preferredSampleRate: Double = 44_100
    let audioFormatDescription: String = "test"

    private let levelSubject = CurrentValueSubject<Double, Never>(0)
    private let clip: RecordedAudioClip

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var cancelCallCount = 0

    var isRecording: Bool = false

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    init(clip: RecordedAudioClip) {
        self.clip = clip
    }

    func startRecording() throws {
        startCallCount += 1
        isRecording = true
    }

    func stopRecording() throws -> RecordedAudioClip {
        stopCallCount += 1
        isRecording = false
        return clip
    }

    func cancelRecording() {
        cancelCallCount += 1
        isRecording = false
    }

    func removeClip(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func purgeStaleTemporaryFiles(olderThan age: TimeInterval) -> Int {
        0
    }
}

@MainActor
private final class FakeTextOutputCoordinator: TextOutputCoordinator {
    var insertionStrategy: String = "test"
    var selectionSnapshot: FocusedSelectionSnapshot?
    var capturedSelectionSnapshot: FocusedSelectionSnapshot?
    var errorToThrow: Error?
    private(set) var lastRequest: TextOutputRequest?
    private(set) var captureSelectionCallCount: Int = 0

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        selectionSnapshot
    }

    func captureSelectionSnapshot() async -> FocusedSelectionSnapshot? {
        captureSelectionCallCount += 1
        return capturedSelectionSnapshot ?? selectionSnapshot
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        if let errorToThrow {
            throw errorToThrow
        }
        lastRequest = request
        return TextOutputResult(
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            didInsertIntoEditor: true,
            operation: request.operation
        )
    }
}

private struct FixedContextDetector: ContextDetector {
    func currentSnapshot() -> ContextSnapshot {
        ContextSnapshot(
            focusContext: focusedAppContext(),
            rewriteAvailable: true,
            styleHint: "test"
        )
    }

    func focusedAppContext() -> FocusedAppContext {
        FocusedAppContext(
            appName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            focusedRole: "AXTextArea",
            hasEditableTarget: true,
            strategyHint: "test"
        )
    }
}

private final class MemoryCredentialStoreForInteractionTests: ProviderCredentialStore {
    private var storage: [String: String]

    init(storage: [String: String] = [:]) {
        self.storage = storage
    }

    func loadAPIKey(for profileID: String) throws -> String? {
        storage[profileID]
    }

    func saveAPIKey(_ value: String, for profileID: String) throws {
        storage[profileID] = value
    }

    func deleteAPIKey(for profileID: String) throws {
        storage.removeValue(forKey: profileID)
    }

    func containsAPIKey(for profileID: String, allowUserInteraction: Bool) throws -> Bool {
        storage[profileID]?.isEmpty == false
    }
}

private final class FakeTranscriptionProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.localSenseVoice]
    private var scriptedResponses: [Result<String, SpeechTranscriptionError>]
    private let fallbackResponse: Result<String, SpeechTranscriptionError>
    private(set) var callCount: Int = 0
    private(set) var lastRequest: SpeechTranscriptionRequest?

    init(transcript: String) {
        let response: Result<String, SpeechTranscriptionError> = .success(transcript)
        self.scriptedResponses = [response]
        self.fallbackResponse = response
    }

    init(scriptedResponses: [Result<String, SpeechTranscriptionError>]) {
        self.scriptedResponses = scriptedResponses
        self.fallbackResponse = scriptedResponses.last ?? .success("fallback")
    }

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult {
        callCount += 1
        lastRequest = request
        _ = configuration
        _ = apiKey
        let response: Result<String, SpeechTranscriptionError>
        if scriptedResponses.isEmpty {
            response = fallbackResponse
        } else {
            response = scriptedResponses.removeFirst()
        }

        switch response {
        case let .success(transcript):
            return SpeechTranscriptionResult(
                providerType: .localSenseVoice,
                providerName: "Fake Local",
                modelName: "sensevoice-small",
                transcript: transcript
            )
        case let .failure(error):
            throw error
        }
    }
}

private final class FakeDictationPostProcessor: DictationPostProcessor {
    enum Result {
        case success(String)
        case failure(Error)
    }

    private let result: Result

    init(result: Result) {
        self.result = result
    }

    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult {
        switch result {
        case let .success(text):
            return DictationPostProcessResult(
                outputText: text,
                providerName: "Fake Text",
                modelName: "fake-model"
            )
        case let .failure(error):
            throw error
        }
    }
}

private final class CountingDictationPostProcessor: DictationPostProcessor {
    private(set) var callCount: Int = 0
    private let outputText: String

    init(outputText: String) {
        self.outputText = outputText
    }

    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult {
        callCount += 1
        return DictationPostProcessResult(
            outputText: outputText,
            providerName: "Fake Text",
            modelName: "fake-model"
        )
    }
}

private final class CapturingDictationPostProcessor: DictationPostProcessor {
    private(set) var lastRequest: DictationPostProcessRequest?
    private let outputText: String

    init(outputText: String) {
        self.outputText = outputText
    }

    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult {
        lastRequest = request
        return DictationPostProcessResult(
            outputText: outputText,
            providerName: "Fake Text",
            modelName: "fake-model"
        )
    }
}

private final class FakeBrainstormContextComposer: BrainstormContextComposer {
    enum Result {
        case success(summaryText: String, dialogueText: String)
        case failure(Error)
    }

    private let result: Result
    private(set) var callCount: Int = 0
    private(set) var lastRequest: BrainstormContextComposeRequest?

    init(result: Result) {
        self.result = result
    }

    func compose(
        request: BrainstormContextComposeRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> BrainstormContextComposeResult {
        lastRequest = request
        _ = configuration
        _ = apiKey
        callCount += 1
        switch result {
        case let .success(summaryText, dialogueText):
            return BrainstormContextComposeResult(
                summaryText: summaryText,
                dialogueText: dialogueText,
                providerName: "Fake Text",
                modelName: "fake-model"
            )
        case let .failure(error):
            throw error
        }
    }
}

private final class FakeMagicianIntentRouter: MagicianIntentRouting {
    private let intent: MagicianIntent

    init(intent: MagicianIntent) {
        self.intent = intent
    }

    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent {
        _ = command
        _ = selection
        _ = enabledFeatures
        return intent
    }
}

private final class DelayedFailingMagicianIntentRouter: MagicianIntentRouting {
    private let delayNanoseconds: UInt64
    private let error: Error

    init(delayNanoseconds: UInt64, error: Error) {
        self.delayNanoseconds = delayNanoseconds
        self.error = error
    }

    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent {
        _ = command
        _ = selection
        _ = enabledFeatures
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        throw error
    }
}

@MainActor
private final class FakeMagicianToolExecutor: MagicianToolExecuting {
    var result: Result<MagicianExecutionResult, Error> = .failure(
        MagicianError(
            code: .toolExecutionFailed,
            userMessage: "fake error",
            debugMessage: nil,
            recoverAction: nil
        )
    )
    private(set) var callCount: Int = 0
    private(set) var lastIntent: MagicianIntent?
    private(set) var lastExecutionContext: MagicianExecutionContext?
    private(set) var lastCommand: String?

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        callCount += 1
        lastIntent = intent
        lastExecutionContext = context
        lastCommand = context.command
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }
}
