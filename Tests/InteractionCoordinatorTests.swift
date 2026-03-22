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

    func testDictationUsesPostProcessedTextWhenSystemPromptEnabled() async throws {
        let postProcessor = FakeDictationPostProcessor(result: .success("整理后的听写"))
        let fixture = try makeFixture(dictationPostProcessor: postProcessor)
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
        let postProcessor = FakeDictationPostProcessor(result: .failure(RewriteProviderError.invalidGeneratedText))
        let fixture = try makeFixture(dictationPostProcessor: postProcessor)
        defer { fixture.cleanUp() }

        fixture.skillRuleStore.setEnabled(true, for: .systemPrompt)
        fixture.skillRuleStore.setParameter("默认更简洁，保留重点。", for: .systemPrompt)

        fixture.coordinator.handleWakeInput(context: .dictation)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(fixture.textOutputCoordinator.lastRequest?.text, "hello world")
        XCTAssertTrue(fixture.sessionStore.statusMessage.contains("已退回本地结果"))
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.outputText, "hello world")
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
        let fixture = try makeFixture(dictationPostProcessor: postProcessor)
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
        let fixture = try makeFixture(dictationPostProcessor: postProcessor)
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

    private func makeFixture(
        textOutputCoordinator: FakeTextOutputCoordinator? = nil,
        dictationPostProcessor: DictationPostProcessor = FakeDictationPostProcessor(result: .success("hello world"))
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
        let transcriptionProvider = FakeTranscriptionProvider()
        let resolvedTextOutputCoordinator = textOutputCoordinator ?? FakeTextOutputCoordinator()

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
            dictationPostProcessor: dictationPostProcessor
        )

        return InteractionFixture(
            coordinator: coordinator,
            sessionStore: sessionStore,
            audioCapture: audioCapture,
            textOutputCoordinator: resolvedTextOutputCoordinator,
            localHistoryStore: localHistoryStore,
            skillRuleStore: skillRuleStore,
            appScenePolicyStore: appScenePolicyStore,
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

private struct FakeTranscriptionProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.localSenseVoice]

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult {
        SpeechTranscriptionResult(
            providerType: .localSenseVoice,
            providerName: "Fake Local",
            modelName: "sensevoice-small",
            transcript: "hello world"
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
