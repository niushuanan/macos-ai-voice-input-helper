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
            transcriptionText: "hello world"
        )
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(postProcessor.callCount, 0)
        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "hello world")
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
        transcriptionText: String = "hello world"
    ) throws -> InteractionFixture {
        let defaultsSuiteName = "InteractionCoordinatorTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw NSError(domain: "InteractionCoordinatorTests", code: 1)
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)

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
        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.interaction.tests")
        let transcriptionProvider = FakeTranscriptionProvider(transcript: transcriptionText)
        let resolvedTextOutputCoordinator = textOutputCoordinator ?? FakeTextOutputCoordinator()
        let dictionaryStore = ASRDictionaryStore(
            defaults: defaults,
            storageKey: "asr.dictionary.interaction.tests"
        )

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
            skillRuleStore: skillRuleStore,
            asrDictionaryStore: dictionaryStore,
            toastPresenter: nil,
            dictationPostProcessor: dictationPostProcessor,
            brainstormContextComposer: brainstormContextComposer
        )

        return InteractionFixture(
            coordinator: coordinator,
            sessionStore: sessionStore,
            audioCapture: audioCapture,
            textOutputCoordinator: resolvedTextOutputCoordinator,
            localHistoryStore: localHistoryStore,
            skillRuleStore: skillRuleStore,
            appScenePolicyStore: appScenePolicyStore,
            transcriptionProvider: transcriptionProvider,
            dictionaryStore: dictionaryStore,
            cleanUp: {
                try? FileManager.default.removeItem(at: historyDirectory)
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
    let skillRuleStore: SkillRuleStore
    let appScenePolicyStore: AppScenePolicyStore
    let transcriptionProvider: FakeTranscriptionProvider
    let dictionaryStore: ASRDictionaryStore
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
    private(set) var lastRequest: TextOutputRequest?

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        selectionSnapshot
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
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
    let transcript: String
    private(set) var lastRequest: SpeechTranscriptionRequest?

    init(transcript: String) {
        self.transcript = transcript
    }

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult {
        lastRequest = request
        return SpeechTranscriptionResult(
            providerType: .localSenseVoice,
            providerName: "Fake Local",
            modelName: "sensevoice-small",
            transcript: transcript
        )
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
