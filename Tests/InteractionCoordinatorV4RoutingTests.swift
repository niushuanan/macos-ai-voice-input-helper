import Combine
import XCTest
@testable import PulseType

@MainActor
final class InteractionCoordinatorV4RoutingTests: XCTestCase {
    func testSelectionRewriteDefaultsToV4Runtime() async throws {
        let v4Runtime = FakeV4MagicianRuntime(
            outcome: makeCompletedOutcome(
                goalSummary: "帮我润色一下",
                finalStatusMessage: "V4 已完成润色",
                finalOutputText: "润色后的文本",
                evidenceSummary: "v4-evidence"
            )
        )
        let legacyRuntime = FakeLegacyMagicianRuntime(
            result: .failure(
                MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "legacy 不应被调用",
                    debugMessage: nil,
                    recoverAction: nil
                )
            )
        )
        let fixture = try makeFixture(
            v4Runtime: v4Runtime,
            legacyNativeRuntime: legacyRuntime,
            legacyAgentRuntime: legacyRuntime,
            transcriptionText: "帮我润色一下"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .textTransform)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(v4Runtime.callCount, 1)
        XCTAssertEqual(legacyRuntime.callCount, 0)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.magicianRuntimeVersion, 4)
    }

    func testLegacyRuntimeEnabledByDebugFlag() async throws {
        let v4Runtime = FakeV4MagicianRuntime(
            outcome: makeCompletedOutcome(
                goalSummary: "帮我润色一下",
                finalStatusMessage: "V4 不应被调用",
                finalOutputText: "V4",
                evidenceSummary: "v4"
            )
        )
        let legacyRuntime = FakeLegacyMagicianRuntime(
            result: .success(
                MagicianAgentRunOutcome(
                    sessionID: "legacy-session",
                    runID: "legacy-run",
                    goalSummary: "帮我润色一下",
                    finalStatusMessage: "legacy 已完成",
                    finalOutputText: "legacy-result",
                    displayText: "legacy",
                    steps: [
                        MagicianAgentStepRecord(
                            id: "legacy-step",
                            featureID: .textTransform,
                            instruction: "帮我润色一下",
                            userMessage: "legacy 已完成",
                            outputText: "legacy-result",
                            observation: nil
                        )
                    ],
                    evidenceSummary: "legacy-evidence"
                )
            )
        )
        let fixture = try makeFixture(
            v4Runtime: v4Runtime,
            legacyNativeRuntime: legacyRuntime,
            legacyAgentRuntime: legacyRuntime,
            runtimeSwitchStore: V4RuntimeSwitchStore(
                environment: [V4RuntimeSwitchStore.legacyRuntimeEnvironmentKey: "1"]
            ),
            transcriptionText: "帮我润色一下"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .textTransform)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(v4Runtime.callCount, 0)
        XCTAssertEqual(legacyRuntime.callCount, 1)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.magicianRuntimeVersion, 2)
    }

    func testPreflightFailureStillRecordsV4WhenLegacyDebugEnabled() async throws {
        let v4Runtime = FakeV4MagicianRuntime(
            outcome: makeCompletedOutcome(
                goalSummary: "不应执行",
                finalStatusMessage: "V4 不应被调用",
                finalOutputText: nil,
                evidenceSummary: "unused"
            )
        )
        let legacyRuntime = FakeLegacyMagicianRuntime(
            result: .failure(
                MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "legacy 不应被调用",
                    debugMessage: nil,
                    recoverAction: nil
                )
            )
        )
        let fixture = try makeFixture(
            v4Runtime: v4Runtime,
            legacyNativeRuntime: legacyRuntime,
            legacyAgentRuntime: legacyRuntime,
            runtimeSwitchStore: V4RuntimeSwitchStore(
                environment: [V4RuntimeSwitchStore.legacyRuntimeEnvironmentKey: "1"]
            ),
            transcriptionText: "发邮件给产品组并同步到飞书"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .composeEmailDraft)
        fixture.magicianFeatureToggleStore.setEnabled(true, for: .feishuCLI)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(v4Runtime.callCount, 0)
        XCTAssertEqual(legacyRuntime.callCount, 0)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.magicianRuntimeVersion, 4)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.status, .failed)
    }

    func testLegacyRuntimeDisabledByDefault() async throws {
        let v4Runtime = FakeV4MagicianRuntime(
            outcome: makeCompletedOutcome(
                goalSummary: "给产品组发飞书消息",
                finalStatusMessage: "V4 已发送",
                finalOutputText: nil,
                evidenceSummary: "message_id=v4"
            )
        )
        let legacyRuntime = FakeLegacyMagicianRuntime(
            result: .failure(
                MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "legacy 不应被调用",
                    debugMessage: nil,
                    recoverAction: nil
                )
            )
        )
        let fixture = try makeFixture(
            v4Runtime: v4Runtime,
            legacyNativeRuntime: legacyRuntime,
            legacyAgentRuntime: legacyRuntime,
            transcriptionText: "给产品组发飞书消息"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .feishuCLI)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        XCTAssertEqual(v4Runtime.callCount, 1)
        XCTAssertEqual(legacyRuntime.callCount, 0)
        XCTAssertEqual(fixture.localHistoryStore.entries.first?.magicianRuntimeVersion, 4)
    }

    func testV4FailureStillWritesHistoryTrace() async throws {
        let outcome = makeFailedOutcome(
            goalSummary: "帮我发飞书",
            finalStatusMessage: "权限未开启",
            failureCode: .permissionDenied
        )
        let event = V4RuntimeEvent(
            name: .runFailed,
            status: .failed,
            sessionID: outcome.sessionID,
            runID: outcome.runID,
            traceID: outcome.traceID,
            lane: outcome.lane,
            goalSummary: outcome.goalSummary,
            message: outcome.finalStatusMessage,
            stepID: nil,
            turnIndex: 1,
            maxTurns: 4,
            stepIndex: nil,
            totalSteps: nil,
            stepRecords: outcome.stepRecords,
            evidenceSummary: outcome.evidenceSummary,
            progressHint: SessionHUDProgressHint.workflowPreview,
            createdAt: Date()
        )
        let fixture = try makeFixture(
            v4Runtime: FakeV4MagicianRuntime(outcome: outcome, events: [event]),
            transcriptionText: "帮我发飞书"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .feishuCLI)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        let history = try XCTUnwrap(fixture.localHistoryStore.entries.first)
        XCTAssertEqual(history.status, .failed)
        XCTAssertEqual(history.magicianRuntimeVersion, 4)
        XCTAssertTrue(history.magicianExecutionTrace?.contains("status: failed") == true)
        XCTAssertTrue(history.magicianExecutionTrace?.contains("run_failed") == true)
        XCTAssertEqual(fixture.sessionStore.phase, .error)
    }

    func testV4SuccessWritesRuntimeVersion4AndStepSummary() async throws {
        let outcome = makeCompletedOutcome(
            goalSummary: "帮我润色一下",
            finalStatusMessage: "V4 已完成润色",
            finalOutputText: "润色后的文本",
            evidenceSummary: "rewrite-evidence"
        )
        let fixture = try makeFixture(
            v4Runtime: FakeV4MagicianRuntime(outcome: outcome),
            transcriptionText: "帮我润色一下"
        )
        defer { fixture.cleanUp() }

        fixture.magicianFeatureToggleStore.setEnabled(true, for: .textTransform)

        fixture.coordinator.handleWakeInput(context: .magicianHold)
        fixture.coordinator.handleStopInput()
        await waitForPipeline(using: fixture.sessionStore)

        let history = try XCTUnwrap(fixture.localHistoryStore.entries.first)
        XCTAssertEqual(history.status, .success)
        XCTAssertEqual(history.magicianRuntimeVersion, 4)
        XCTAssertEqual(history.magicianSessionID, outcome.sessionID.rawValue)
        XCTAssertEqual(history.magicianRunID, outcome.runID.rawValue)
        XCTAssertEqual(history.magicianGoalSummary, "帮我润色一下")
        XCTAssertEqual(history.magicianEvidenceSummary, "rewrite-evidence")
        XCTAssertEqual(history.magicianStepSummaries, ["text.transform:润色后的文本"])
    }

    private func makeFixture(
        defaults: UserDefaults? = nil,
        v4Runtime: (any V4MagicianRuntimeRunning)? = nil,
        legacyNativeRuntime: (any MagicianAgentRunning)? = nil,
        legacyAgentRuntime: (any MagicianAgentRunning)? = nil,
        runtimeSwitchStore: V4RuntimeSwitchStore? = nil,
        transcriptionText: String
    ) throws -> V4RoutingFixture {
        let defaults: UserDefaults = try {
            if let defaults {
                return defaults
            }
            return try makeDefaults()
        }()
        let suiteName = try XCTUnwrap(defaultsSuiteName(for: defaults))
        defaults.removePersistentDomain(forName: suiteName)

        let historyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-v4-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let diagnosticsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-v4-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
        let clipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("interaction-v4-clip-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Data([0x01, 0x02]).write(to: clipURL)

        let sessionStore = SessionStore()
        let permissionsCenter = PermissionsCenter(
            defaults: defaults,
            microphoneStateResolver: { .granted },
            accessibilityStateResolver: { .granted }
        )
        let audioCapture = FakeRoutingAudioCaptureService(
            clip: RecordedAudioClip(
                id: UUID(),
                fileURL: clipURL,
                duration: 0.8,
                sampleRate: 44_100,
                createdAt: Date()
            )
        )
        let providerSettingsStore = ProviderSettingsStore(
            defaults: defaults,
            credentialStore: RoutingCredentialStore(storage: ["text.primary": "sk-test-000000"])
        )
        providerSettingsStore.updateASRProviderType(.localSenseVoice)

        let localHistoryStore = LocalHistoryStore(historyDirectory: historyDirectory)
        let brainstormDurationProfileStore = BrainstormDurationProfileStore(historyDirectory: historyDirectory)
        let speechPipelineLogger = SpeechPipelineLogger(diagnosticsDirectory: diagnosticsDirectory)
        let workflowTelemetryReporter = WorkflowTelemetryReporter(
            diagnosticsDirectory: diagnosticsDirectory,
            speechPipelineLogger: speechPipelineLogger
        )
        let appScenePolicyStore = AppScenePolicyStore(defaults: defaults)
        let skillRuleStore = SkillRuleStore(defaults: defaults, storageKey: "skill.rules.interaction.v4.tests")
        let magicianFeatureToggleStore = MagicianFeatureToggleStore(
            defaults: defaults,
            storageKey: "magician.permission_scopes.interaction.v4.tests",
            legacyStorageKey: "magician.features.interaction.v4.tests"
        )
        magicianFeatureToggleStore.resetAll()
        let textOutputCoordinator = FakeRoutingTextOutputCoordinator()
        let dictionaryStore = ASRDictionaryStore(
            defaults: defaults,
            storageKey: "asr.dictionary.interaction.v4.tests"
        )
        let runtimeSwitchStore = runtimeSwitchStore ?? V4RuntimeSwitchStore(
            defaults: defaults,
            environment: [:]
        )
        let coordinator = InteractionCoordinator(
            sessionStore: sessionStore,
            permissionsCenter: permissionsCenter,
            audioCaptureService: audioCapture,
            providerSettingsStore: providerSettingsStore,
            providerRegistry: SpeechProviderRegistry(
                providers: [FakeRoutingTranscriptionProvider(transcript: transcriptionText)]
            ),
            rewriteProviderRegistry: RewriteProviderRegistry(providers: []),
            textOutputCoordinator: textOutputCoordinator,
            contextDetector: FixedRoutingContextDetector(),
            appScenePolicyStore: appScenePolicyStore,
            localHistoryStore: localHistoryStore,
            brainstormDurationProfileStore: brainstormDurationProfileStore,
            speechPipelineLogger: speechPipelineLogger,
            skillRuleStore: skillRuleStore,
            asrDictionaryStore: dictionaryStore,
            magicianFeatureToggleStore: magicianFeatureToggleStore,
            workflowTelemetryReporter: workflowTelemetryReporter,
            magicianToolExecutor: MagicianToolExecutor(),
            v4MagicianRuntime: v4Runtime,
            v4RuntimeSwitchStore: runtimeSwitchStore,
            magicianNativeRuntime: legacyNativeRuntime,
            magicianAgentRuntime: legacyAgentRuntime
        )

        return V4RoutingFixture(
            coordinator: coordinator,
            sessionStore: sessionStore,
            localHistoryStore: localHistoryStore,
            magicianFeatureToggleStore: magicianFeatureToggleStore,
            cleanUp: {
                try? FileManager.default.removeItem(at: historyDirectory)
                try? FileManager.default.removeItem(at: diagnosticsDirectory)
                try? FileManager.default.removeItem(at: clipURL)
                defaults.removePersistentDomain(forName: suiteName)
            }
        )
    }

    private func waitForPipeline(
        using sessionStore: SessionStore,
        timeoutNanoseconds: UInt64 = 4_000_000_000
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if sessionStore.phase == .idle || sessionStore.phase == .error || sessionStore.phase == .cancelled {
                return
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "InteractionCoordinatorV4RoutingTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "InteractionCoordinatorV4RoutingTests", code: 1)
        }
        defaults.set(suiteName, forKey: "__suite_name")
        return defaults
    }

    private func defaultsSuiteName(for defaults: UserDefaults) -> String? {
        defaults.string(forKey: "__suite_name")
    }

    private func makeCompletedOutcome(
        goalSummary: String,
        finalStatusMessage: String,
        finalOutputText: String?,
        evidenceSummary: String
    ) -> V4RunOutcome {
        let sessionID = V4SessionID(rawValue: "v4-session-\(UUID().uuidString)")
        let runID = V4RunID(rawValue: "v4-run-\(UUID().uuidString)")
        let traceID = V4TraceID(rawValue: "v4-trace-\(UUID().uuidString)")
        return V4RunOutcome(
            sessionID: sessionID,
            runID: runID,
            traceID: traceID,
            lane: .selectionRewrite,
            goalSummary: goalSummary,
            status: .completed,
            finalStatusMessage: finalStatusMessage,
            finalOutputText: finalOutputText,
            displayText: "V4 success",
            stepRecords: [
                V4StepRecord(
                    id: V4StepID(rawValue: "v4-step-1"),
                    traceID: traceID,
                    lane: .selectionRewrite,
                    goalSummary: goalSummary,
                    title: goalSummary,
                    status: .completed,
                    toolName: "text.transform",
                    inputSummary: goalSummary,
                    outputSummary: finalOutputText,
                    evidenceSummary: evidenceSummary,
                    startedAt: Date(),
                    finishedAt: Date(),
                    failureCode: nil,
                    attemptCount: 1
                )
            ],
            evidenceSummary: evidenceSummary,
            failureCode: nil,
            finishedAt: Date()
        )
    }

    private func makeFailedOutcome(
        goalSummary: String,
        finalStatusMessage: String,
        failureCode: V4FailureCode
    ) -> V4RunOutcome {
        let sessionID = V4SessionID(rawValue: "v4-session-\(UUID().uuidString)")
        let runID = V4RunID(rawValue: "v4-run-\(UUID().uuidString)")
        let traceID = V4TraceID(rawValue: "v4-trace-\(UUID().uuidString)")
        return V4RunOutcome(
            sessionID: sessionID,
            runID: runID,
            traceID: traceID,
            lane: .selectionRewrite,
            goalSummary: goalSummary,
            status: .failed,
            finalStatusMessage: finalStatusMessage,
            finalOutputText: nil,
            displayText: "V4 failed",
            stepRecords: [
                V4StepRecord(
                    id: V4StepID(rawValue: "v4-step-failed"),
                    traceID: traceID,
                    lane: .selectionRewrite,
                    goalSummary: goalSummary,
                    title: goalSummary,
                    status: .failed,
                    toolName: "feishu.cli",
                    inputSummary: goalSummary,
                    outputSummary: finalStatusMessage,
                    evidenceSummary: "",
                    startedAt: Date(),
                    finishedAt: Date(),
                    failureCode: failureCode,
                    attemptCount: 1
                )
            ],
            evidenceSummary: "",
            failureCode: failureCode,
            finishedAt: Date()
        )
    }
}

private struct V4RoutingFixture {
    let coordinator: InteractionCoordinator
    let sessionStore: SessionStore
    let localHistoryStore: LocalHistoryStore
    let magicianFeatureToggleStore: MagicianFeatureToggleStore
    let cleanUp: () -> Void
}

private final class FakeV4MagicianRuntime: V4MagicianRuntimeRunning, @unchecked Sendable {
    private let events: [V4RuntimeEvent]
    private let outcome: V4RunOutcome

    private(set) var callCount: Int = 0
    private(set) var lastRequest: V4RunRequest?

    init(outcome: V4RunOutcome, events: [V4RuntimeEvent] = []) {
        self.outcome = outcome
        self.events = events
    }

    func run(
        request: V4RunRequest,
        onEvent: (@Sendable (V4RuntimeEvent) -> Void)?
    ) async throws -> V4RunOutcome {
        callCount += 1
        lastRequest = request
        for event in events {
            onEvent?(event)
        }
        return outcome
    }
}

private final class FakeLegacyMagicianRuntime: MagicianAgentRunning {
    let result: Result<MagicianAgentRunOutcome, Error>

    private(set) var callCount: Int = 0
    private(set) var lastRequest: MagicianAgentRequest?

    init(result: Result<MagicianAgentRunOutcome, Error>) {
        self.result = result
    }

    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome {
        callCount += 1
        lastRequest = request
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .requestAccepted,
                state: .planning,
                message: "legacy planning",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )
        return try result.get()
    }
}

@MainActor
private final class FakeRoutingAudioCaptureService: AudioCaptureService {
    let preferredSampleRate: Double = 44_100
    let audioFormatDescription: String = "test"
    var isRecording: Bool = false

    private let levelSubject = CurrentValueSubject<Double, Never>(0)
    private let clip: RecordedAudioClip

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject.eraseToAnyPublisher()
    }

    init(clip: RecordedAudioClip) {
        self.clip = clip
    }

    func startRecording() throws {
        isRecording = true
    }

    func stopRecording() throws -> RecordedAudioClip {
        isRecording = false
        return clip
    }

    func cancelRecording() {
        isRecording = false
    }

    func removeClip(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func purgeStaleTemporaryFiles(olderThan age: TimeInterval) -> Int {
        0
    }
}

private final class FakeRoutingTranscriptionProvider: SpeechTranscriptionProvider {
    let supportedProviderTypes: [ProviderType] = [.localSenseVoice]
    private let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func transcribe(
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String
    ) async throws -> SpeechTranscriptionResult {
        _ = request
        _ = configuration
        _ = apiKey
        return SpeechTranscriptionResult(
            providerType: .localSenseVoice,
            providerName: "Fake Local",
            modelName: "sensevoice-small",
            transcript: transcript
        )
    }
}

@MainActor
private final class FakeRoutingTextOutputCoordinator: TextOutputCoordinator {
    let insertionStrategy: String = "test"
    var selectionSnapshot: FocusedSelectionSnapshot?

    func currentSelectionSnapshot() -> FocusedSelectionSnapshot? {
        selectionSnapshot
    }

    func captureSelectionSnapshot() async -> FocusedSelectionSnapshot? {
        selectionSnapshot
    }

    func write(request: TextOutputRequest) async throws -> TextOutputResult {
        TextOutputResult(
            appName: request.focusContext.appName,
            bundleID: request.focusContext.bundleID,
            path: .accessibilitySelectionReplacement,
            usedFallback: false,
            didInsertIntoEditor: true,
            operation: request.operation
        )
    }
}

private struct FixedRoutingContextDetector: ContextDetector {
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

private final class RoutingCredentialStore: ProviderCredentialStore {
    private var storage: [String: String]

    init(storage: [String: String]) {
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
        _ = allowUserInteraction
        return storage[profileID]?.isEmpty == false
    }
}
