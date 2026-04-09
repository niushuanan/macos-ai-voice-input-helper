import AppKit
import Combine
import Foundation

@MainActor
final class InteractionCoordinator {
    private let sessionStore: SessionStore
    private let permissionsCenter: PermissionsCenter
    private let audioCaptureService: AudioCaptureService
    private let providerSettingsStore: ProviderSettingsStore
    private let providerRegistry: SpeechProviderRegistry
    private let rewriteProviderRegistry: RewriteProviderRegistry
    private let textOutputCoordinator: TextOutputCoordinator
    private let contextDetector: ContextDetector
    private let appScenePolicyStore: AppScenePolicyStore
    private let localHistoryStore: LocalHistoryStore
    private let brainstormDurationProfileStore: BrainstormDurationProfileStore
    private let speechPipelineLogger: SpeechPipelineLogger
    private let skillRuleStore: SkillRuleStore
    private let asrDictionaryStore: ASRDictionaryStore
    private let magicianFeatureToggleStore: MagicianFeatureToggleStore
    private let workflowTelemetryReporter: any WorkflowTelemetryReporting
    private let magicianLaneRouter: any MagicianLaneRouting
    private let musicFastExecutor: any MusicFastExecuting
    private let musicExecutionInterpreter: any MusicExecutionInterpreting
    private let v4MagicianRuntime: any V4MagicianRuntimeRunning
    private let v4RuntimeSwitchStore: V4RuntimeSwitchStore
    private let v4SessionStoreBridge: V4ToSessionStoreBridge
    private let v4HistoryBridge: V4ToHistoryBridge
    private let v4MemoryPlannerInputAdapter: any V4MemoryQueryPlannerInputAdapting
    // legacy fallback only, debug 模式下按需装配
    private let legacyRuntimeResolver: any LegacyMagicianRuntimeResolving
    private let toastPresenter: ToastPresenter?
    private let dictationPostProcessor: DictationPostProcessor
    private let brainstormContextComposer: BrainstormContextComposer
    private var cancellables = Set<AnyCancellable>()
    private var transcriptionTask: Task<Void, Never>?
    private var currentDictationTarget: DictationWritebackTarget?
    private var lastExternalDictationTarget: DictationWritebackTarget?
    private var lastDictionaryTruncationSignature: Int?
    private var lastBrainstormBlockedByDictationAt: Date?
    private var currentTraceID: String?
    private var brainstormAutoStopTask: Task<Void, Never>?
    private var brainstormAutoStopHasTriggered = false
    private var brainstormProbeTask: Task<Void, Never>?
    private var probingProfileKey: String?

    init(
        sessionStore: SessionStore,
        permissionsCenter: PermissionsCenter,
        audioCaptureService: AudioCaptureService,
        providerSettingsStore: ProviderSettingsStore,
        providerRegistry: SpeechProviderRegistry,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        appScenePolicyStore: AppScenePolicyStore,
        localHistoryStore: LocalHistoryStore,
        brainstormDurationProfileStore: BrainstormDurationProfileStore,
        speechPipelineLogger: SpeechPipelineLogger,
        skillRuleStore: SkillRuleStore,
        asrDictionaryStore: ASRDictionaryStore,
        mailAddressBookStore: MailAddressBookStore? = nil,
        magicianFeatureToggleStore: MagicianFeatureToggleStore? = nil,
        workflowTelemetryReporter: (any WorkflowTelemetryReporting)? = nil,
        magicianLaneRouter: (any MagicianLaneRouting)? = nil,
        musicFastExecutor: (any MusicFastExecuting)? = nil,
        musicExecutionInterpreter: (any MusicExecutionInterpreting)? = nil,
        magicianToolExecutor: (any MagicianToolExecuting)? = nil,
        v4MagicianRuntime: (any V4MagicianRuntimeRunning)? = nil,
        v4RuntimeSwitchStore: V4RuntimeSwitchStore? = nil,
        v4SessionStoreBridge: V4ToSessionStoreBridge? = nil,
        v4HistoryBridge: V4ToHistoryBridge = V4ToHistoryBridge(),
        v4MemoryPlannerInputAdapter: (any V4MemoryQueryPlannerInputAdapting)? = nil,
        legacyRuntimeResolver: (any LegacyMagicianRuntimeResolving)? = nil,
        magicianNativeRuntime: (any MagicianAgentRunning)? = nil,
        magicianAgentRuntime: (any MagicianAgentRunning)? = nil,
        toastPresenter: ToastPresenter? = nil,
        dictationPostProcessor: DictationPostProcessor = LLMDictationPostProcessor(),
        brainstormContextComposer: BrainstormContextComposer = LLMBrainstormContextComposer()
    ) {
        self.sessionStore = sessionStore
        self.permissionsCenter = permissionsCenter
        self.audioCaptureService = audioCaptureService
        self.providerSettingsStore = providerSettingsStore
        self.providerRegistry = providerRegistry
        self.rewriteProviderRegistry = rewriteProviderRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.appScenePolicyStore = appScenePolicyStore
        self.localHistoryStore = localHistoryStore
        self.brainstormDurationProfileStore = brainstormDurationProfileStore
        self.speechPipelineLogger = speechPipelineLogger
        self.skillRuleStore = skillRuleStore
        self.asrDictionaryStore = asrDictionaryStore
        self.magicianFeatureToggleStore = magicianFeatureToggleStore ?? MagicianFeatureToggleStore()
        self.workflowTelemetryReporter = workflowTelemetryReporter ?? WorkflowTelemetryReporter(
            speechPipelineLogger: speechPipelineLogger
        )
        if let magicianLaneRouter {
            self.magicianLaneRouter = magicianLaneRouter
        } else {
            let providerSettingsBridge = V4ProviderSettingsBridge(providerSettingsStore: providerSettingsStore)
            let modelSlotManager = V4ModelSlotManager(bridge: providerSettingsBridge)
            self.magicianLaneRouter = MagicianSemanticLaneRouter(modelSlotManager: modelSlotManager)
        }
        self.musicFastExecutor = musicFastExecutor ?? MusicFastExecutor(providerSettingsStore: providerSettingsStore)
        self.musicExecutionInterpreter = musicExecutionInterpreter ?? MusicExecutionInterpreter(
            providerSettingsStore: providerSettingsStore
        )
        self.v4RuntimeSwitchStore = v4RuntimeSwitchStore ?? V4RuntimeSwitchStore()
        self.v4SessionStoreBridge = v4SessionStoreBridge ?? V4ToSessionStoreBridge()
        self.v4HistoryBridge = v4HistoryBridge
        self.v4MemoryPlannerInputAdapter = v4MemoryPlannerInputAdapter ?? V4MemoryQueryPlannerInputAdapter()
        self.v4MagicianRuntime = v4MagicianRuntime ?? V4MagicianRuntimeAdapter(
            providerSettingsStore: providerSettingsStore,
            skillRuleStore: skillRuleStore,
            appScenePolicyStore: appScenePolicyStore,
            featureToggleStore: self.magicianFeatureToggleStore
        )
        self.legacyRuntimeResolver = legacyRuntimeResolver ?? LegacyMagicianRuntimeResolver(
            providerSettingsStore: providerSettingsStore,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            skillRuleStore: skillRuleStore,
            mailAddressBookStore: mailAddressBookStore,
            magicianToolExecutor: magicianToolExecutor,
            magicianNativeRuntime: magicianNativeRuntime,
            magicianAgentRuntime: magicianAgentRuntime
        )
        self.toastPresenter = toastPresenter
        self.dictationPostProcessor = dictationPostProcessor
        self.brainstormContextComposer = brainstormContextComposer
        bindListeningLevel()
        bindExternalAppTracking()
    }

    func handleWakeInput(context: WakeInvocationContext = .dictation) {
        permissionsCenter.refreshStatuses()

        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            discardPendingClipIfNeeded()

            guard permissionsCenter.snapshot.canStartVoiceSession else {
                sessionStore.fail(message: "开始语音会话前，需要先允许麦克风权限。")
                return
            }

            if context.source == .magicianHold, !magicianFeatureToggleStore.hasAnyEnabledFeature() {
                sessionStore.fail(message: "魔术先生能力都还没开启，请先在魔术先生页面打开开关。")
                return
            }

            let lane = resolvedLane(context: context)
            startRecordingAndTransition(lane: lane)
        case .listening:
            if context.source == .dictationTap {
                handleStopInput()
            }
        case .transcribing, .rewriting, .inserting:
            break
        }
    }

    func handleBrainstormInput() {
        permissionsCenter.refreshStatuses()

        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            discardPendingClipIfNeeded()

            guard permissionsCenter.snapshot.canStartVoiceSession else {
                sessionStore.fail(message: "开始语音会话前，需要先允许麦克风权限。")
                return
            }

            startRecordingAndTransition(lane: .brainstormDiscussion)
        case .listening:
            guard sessionStore.activeLane == .brainstormDiscussion else {
                notifyBrainstormBlockedByDictationIfNeeded()
                return
            }
            handleStopInput()
        case .transcribing, .rewriting, .inserting:
            break
        }
    }

    func ensureBrainstormDurationProfile(force: Bool = false) {
        let configuration = providerSettingsStore.configuration
        let profileKey = brainstormProfileKey(
            providerType: configuration.providerType,
            modelName: configuration.modelName
        )
        if
            !force,
            brainstormDurationProfileStore.hasFreshProfile(
                for: configuration.providerType,
                modelName: configuration.modelName
            )
        {
            return
        }

        if probingProfileKey == profileKey, brainstormProbeTask != nil {
            return
        }

        brainstormProbeTask?.cancel()
        probingProfileKey = profileKey
        brainstormProbeTask = Task { [weak self] in
            guard let self else {
                return
            }
            let profile = await self.measureBrainstormDurationProfile(
                configuration: configuration
            )
            guard !Task.isCancelled else {
                return
            }
            self.brainstormDurationProfileStore.upsert(profile)
            self.probingProfileKey = nil
            self.brainstormProbeTask = nil
        }
    }

    private func notifyBrainstormBlockedByDictationIfNeeded() {
        let now = Date()
        if
            let lastBrainstormBlockedByDictationAt,
            now.timeIntervalSince(lastBrainstormBlockedByDictationAt) < 1.2
        {
            return
        }
        self.lastBrainstormBlockedByDictationAt = now
        toastPresenter?.show("当前是普通语音输入，脑暴双击已忽略。请先停止本次录音。")
    }

    func handleStopInput() {
        guard sessionStore.phase == .listening else {
            return
        }
        cancelBrainstormDurationGuard()
        let configuration = providerSettingsStore.configuration
        let traceID = ensureTraceID()
        // 先切到转写阶段，避免 stopRecording 收尾期间 HUD 停在“聆听中”造成卡顿感。
        sessionStore.markTranscribing()
        do {
            let clip = try audioCaptureService.stopRecording()
            speechPipelineLogger.log(
                traceID: traceID,
                lane: sessionStore.activeLane,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "recording.stop",
                audioDuration: clip.duration
            )
            discardPendingClipIfNeeded()
            sessionStore.attachPendingClip(clip)
            sessionStore.updateListeningLevel(0)
            sessionStore.markTranscribing(
                audioSummary: clip.displaySummary,
                providerName: configuration.providerName,
                modelName: configuration.modelName
            )
            startTranscription(for: clip)
        } catch {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: sessionStore.activeLane,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "recording.stop.failed",
                errorType: "audioStopFailed",
                detail: error.localizedDescription
            )
            sessionStore.fail(message: "停止录音失败：\(error.localizedDescription)")
            currentTraceID = nil
        }
    }

    func handleCancelInput() {
        guard sessionStore.phase != .idle else {
            return
        }
        cancelBrainstormDurationGuard()

        let focusContext = contextDetector.focusedAppContext()
        let mode = historyMode(for: sessionStore.activeLane)
        let latestInput = sessionStore.latestTranscription?.transcript ?? ""
        let clipDuration = sessionStore.pendingClip?.duration
        let traceID = ensureTraceID()

        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentDictationTarget = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.cancel()

        localHistoryStore.append(
            SessionHistoryEntry(
                mode: mode,
                appName: focusContext.appName,
                bundleID: focusContext.bundleID,
                inputText: latestInput,
                outputText: nil,
                magicianRuntimeVersion: mode == .selectionRewrite ? 2 : nil,
                status: .cancelled,
                errorMessage: "用户取消了当前会话。",
                audioDurationSeconds: clipDuration
            )
        )
        speechPipelineLogger.log(
            traceID: traceID,
            lane: sessionStore.activeLane,
            provider: nil,
            model: nil,
            httpStatus: nil,
            stage: "history.cancelled",
            detail: "mode=\(mode.rawValue)",
            audioDuration: clipDuration
        )
        currentTraceID = nil
    }

    func handleCompleteInput() {
        guard sessionStore.phase == .inserting else {
            return
        }
        cancelBrainstormDurationGuard()
        currentDictationTarget = nil
        discardPendingClipIfNeeded()
        sessionStore.completeInsertion()
        currentTraceID = nil
    }

    func handleResetInput() {
        cancelBrainstormDurationGuard()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentDictationTarget = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.reset()
        currentTraceID = nil
    }

    private func startRecordingAndTransition(lane: InputLane) {
        let configuration = providerSettingsStore.configuration
        let traceID = UUID().uuidString
        currentTraceID = traceID
        brainstormAutoStopHasTriggered = false

        do {
            if lane == .directDictation || lane == .brainstormDiscussion {
                currentDictationTarget = resolveDictationWritebackTarget()
            } else {
                currentDictationTarget = nil
            }
            try audioCaptureService.startRecording()
            switch lane {
            case .directDictation:
                sessionStore.startDictation()
            case .selectionRewrite:
                sessionStore.startRewrite()
            case .brainstormDiscussion:
                sessionStore.startBrainstorm()
            }
            speechPipelineLogger.log(
                traceID: traceID,
                lane: lane,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "session.start"
            )
            if lane == .brainstormDiscussion {
                armBrainstormDurationGuard(
                    configuration: configuration,
                    traceID: traceID
                )
                ensureBrainstormDurationProfile()
            } else {
                cancelBrainstormDurationGuard()
            }
        } catch {
            cancelBrainstormDurationGuard()
            currentDictationTarget = nil
            sessionStore.fail(message: "无法开始录音：\(error.localizedDescription)")
            speechPipelineLogger.log(
                traceID: traceID,
                lane: lane,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "session.start.failed",
                errorType: "audioStartFailed",
                detail: error.localizedDescription
            )
            currentTraceID = nil
        }
    }

    private func normalizedSelectionSnapshot(_ snapshot: FocusedSelectionSnapshot?) -> FocusedSelectionSnapshot? {
        guard let snapshot else {
            return nil
        }
        let normalized = snapshot.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        return FocusedSelectionSnapshot(
            focusContext: snapshot.focusContext,
            selectedText: normalized
        )
    }

    private func resolveMagicianSelectionSnapshot(
        mode: MagicianSelectionMode,
        seedSnapshot: FocusedSelectionSnapshot?
    ) async -> FocusedSelectionSnapshot? {
        if mode == .none {
            return nil
        }

        if let normalizedSeed = normalizedSelectionSnapshot(seedSnapshot) {
            return normalizedSeed
        }

        if mode == .optional {
            return nil
        }

        if
            let warmableCoordinator = textOutputCoordinator as? AccessibilityTextOutputCoordinator,
            let externalTarget = lastExternalDictationTarget
        {
            await warmableCoordinator.prepareForWrite(
                preferredTarget: externalTarget.snapshot,
                fallbackFocusContext: externalTarget.focusContext
            )
        }

        let preferredTarget = lastExternalDictationTarget?.snapshot
        let captured = await textOutputCoordinator.captureSelectionSnapshot(preferredTarget: preferredTarget)
        return normalizedSelectionSnapshot(captured)
    }

    private func ensureTraceID() -> String {
        if let currentTraceID {
            return currentTraceID
        }
        let newTraceID = UUID().uuidString
        currentTraceID = newTraceID
        return newTraceID
    }

    @discardableResult
    private func abortIfSessionCancelled() -> Bool {
        guard Task.isCancelled || sessionStore.phase == .cancelled else {
            return false
        }
        currentDictationTarget = nil
        return true
    }

    private func transcribeWithRetryOnInvalidResponse(
        provider: any SpeechTranscriptionProvider,
        request: SpeechTranscriptionRequest,
        configuration: SpeechProviderConfiguration,
        apiKey: String,
        traceID: String
    ) async throws -> ASRTranscriptionOutcome {
        for attempt in 1...2 {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: request.lane,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "asr.attempt.start",
                detail: "attempt=\(attempt)",
                audioDuration: request.clip.duration
            )

            do {
                let result = try await provider.transcribe(
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey
                )
                return ASRTranscriptionOutcome(
                    result: result,
                    attempts: attempt
                )
            } catch let speechError as SpeechTranscriptionError {
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: request.lane,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: speechError),
                    stage: "asr.attempt.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: speechError),
                    detail: SpeechTranscriptionErrorPresentation.actionableMessage(for: speechError),
                    audioDuration: request.clip.duration
                )
                if case .invalidResponse = speechError, attempt == 1 {
                    speechPipelineLogger.log(
                        traceID: traceID,
                        lane: request.lane,
                        provider: configuration.providerName,
                        model: configuration.modelName,
                        httpStatus: nil,
                        stage: "asr.retry",
                        errorType: "invalidResponse",
                        detail: "retry-with-original-params",
                        audioDuration: request.clip.duration
                    )
                    continue
                }
                throw ASRTranscriptionFailure(
                    error: speechError,
                    attempts: attempt
                )
            } catch {
                let wrapped = SpeechTranscriptionError.providerFailure(
                    description: error.localizedDescription
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: request.lane,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: wrapped),
                    stage: "asr.attempt.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: wrapped),
                    detail: SpeechTranscriptionErrorPresentation.actionableMessage(for: wrapped),
                    audioDuration: request.clip.duration
                )
                throw ASRTranscriptionFailure(
                    error: wrapped,
                    attempts: attempt
                )
            }
        }

        throw ASRTranscriptionFailure(
            error: .invalidResponse,
            attempts: 2
        )
    }

    private func armBrainstormDurationGuard(
        configuration: SpeechProviderConfiguration,
        traceID: String
    ) {
        cancelBrainstormDurationGuard()
        let profile = brainstormDurationProfileStore.effectiveProfile(
            for: configuration.providerType,
            modelName: configuration.modelName
        )
        let maxSeconds = max(1, profile.maxSeconds)
        speechPipelineLogger.log(
            traceID: traceID,
            lane: .brainstormDiscussion,
            provider: configuration.providerName,
            model: configuration.modelName,
            httpStatus: nil,
            stage: "brainstorm.limit.active",
            detail: "maxSeconds=\(maxSeconds)"
        )

        brainstormAutoStopTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(maxSeconds) * 1_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self.handleBrainstormDurationLimitReached(
                    traceID: traceID,
                    configuration: configuration,
                    maxSeconds: maxSeconds
                )
            }
        }
    }

    private func cancelBrainstormDurationGuard() {
        brainstormAutoStopTask?.cancel()
        brainstormAutoStopTask = nil
    }

    private func handleBrainstormDurationLimitReached(
        traceID: String,
        configuration: SpeechProviderConfiguration,
        maxSeconds: Int
    ) {
        guard !brainstormAutoStopHasTriggered else {
            return
        }
        guard currentTraceID == traceID else {
            return
        }
        guard
            sessionStore.phase == .listening,
            sessionStore.activeLane == .brainstormDiscussion,
            audioCaptureService.isRecording
        else {
            return
        }

        brainstormAutoStopHasTriggered = true
        speechPipelineLogger.log(
            traceID: traceID,
            lane: .brainstormDiscussion,
            provider: configuration.providerName,
            model: configuration.modelName,
            httpStatus: nil,
            stage: "brainstorm.limit.hit",
            detail: "maxSeconds=\(maxSeconds)"
        )
        toastPresenter?.show("已到脑暴时长上限，已自动结束录音并开始整理。")
        handleStopInput()
    }

    private func measureBrainstormDurationProfile(
        configuration: SpeechProviderConfiguration
    ) async -> BrainstormDurationProfile {
        let probeTraceID = "probe-\(UUID().uuidString)"
        speechPipelineLogger.log(
            traceID: probeTraceID,
            lane: .brainstormDiscussion,
            provider: configuration.providerName,
            model: configuration.modelName,
            httpStatus: nil,
            stage: "brainstorm.probe.start"
        )

        guard let provider = providerRegistry.provider(for: configuration.providerType) else {
            speechPipelineLogger.log(
                traceID: probeTraceID,
                lane: .brainstormDiscussion,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "brainstorm.probe.fallback",
                errorType: "missingProvider",
                detail: "当前构建不含所选 provider。"
            )
            return .fallback(
                providerType: configuration.providerType,
                modelName: configuration.modelName
            )
        }

        let apiKey: String
        if configuration.providerType.requiresAPIKey {
            guard
                let loadedKey = try? providerSettingsStore.loadAPIKeyForTranscriptionProvider(),
                !loadedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                speechPipelineLogger.log(
                    traceID: probeTraceID,
                    lane: .brainstormDiscussion,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: nil,
                    stage: "brainstorm.probe.fallback",
                    errorType: "missingAPIKey"
                )
                return .fallback(
                    providerType: configuration.providerType,
                    modelName: configuration.modelName
                )
            }
            apiKey = loadedKey
        } else {
            apiKey = ""
        }

        let maxSeconds = await BrainstormDurationProbePlanner.resolveMaxSeconds { [weak self] duration in
            guard let self else {
                return false
            }
            return await self.probeBrainstormDuration(
                durationSeconds: duration,
                provider: provider,
                configuration: configuration,
                apiKey: apiKey,
                traceID: probeTraceID
            )
        }
        let recommendedSeconds = BrainstormDurationProbePlanner.recommendedSeconds(
            maxSeconds: maxSeconds
        )
        let profile = BrainstormDurationProfile(
            providerType: configuration.providerType,
            modelName: configuration.modelName,
            maxSeconds: maxSeconds,
            recommendedSeconds: recommendedSeconds,
            measuredAt: Date()
        )

        speechPipelineLogger.log(
            traceID: probeTraceID,
            lane: .brainstormDiscussion,
            provider: configuration.providerName,
            model: configuration.modelName,
            httpStatus: nil,
            stage: "brainstorm.probe.success",
            detail: "maxSeconds=\(maxSeconds),recommendedSeconds=\(recommendedSeconds)"
        )
        return profile
    }

    private func probeBrainstormDuration(
        durationSeconds: Int,
        provider: any SpeechTranscriptionProvider,
        configuration: SpeechProviderConfiguration,
        apiKey: String,
        traceID: String
    ) async -> Bool {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainstorm-probe-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            let waveData = makeSilentWAV(durationSeconds: durationSeconds)
            try waveData.write(to: fileURL, options: .atomic)
            let clip = RecordedAudioClip(
                id: UUID(),
                fileURL: fileURL,
                duration: TimeInterval(durationSeconds),
                sampleRate: 16_000,
                createdAt: Date()
            )
            let request = SpeechTranscriptionRequest(
                clip: clip,
                lane: .brainstormDiscussion,
                contextSummary: "duration-probe-\(durationSeconds)"
            )

            do {
                _ = try await provider.transcribe(
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .brainstormDiscussion,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: nil,
                    stage: "brainstorm.probe.attempt.success",
                    detail: "durationSeconds=\(durationSeconds)"
                )
                return true
            } catch let speechError as SpeechTranscriptionError {
                if case .invalidResponse = speechError {
                    // 静音音频可能返回空文本，但链路本身可承载该时长。
                    speechPipelineLogger.log(
                        traceID: traceID,
                        lane: .brainstormDiscussion,
                        provider: configuration.providerName,
                        model: configuration.modelName,
                        httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: speechError),
                        stage: "brainstorm.probe.attempt.success",
                        detail: "durationSeconds=\(durationSeconds),emptyTranscriptAsSuccess"
                    )
                    return true
                }
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .brainstormDiscussion,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: speechError),
                    stage: "brainstorm.probe.attempt.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: speechError),
                    detail: "durationSeconds=\(durationSeconds),\(SpeechTranscriptionErrorPresentation.actionableMessage(for: speechError))"
                )
                return false
            } catch {
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .brainstormDiscussion,
                    provider: configuration.providerName,
                    model: configuration.modelName,
                    httpStatus: nil,
                    stage: "brainstorm.probe.attempt.failed",
                    errorType: "providerFailure",
                    detail: "durationSeconds=\(durationSeconds),\(error.localizedDescription)"
                )
                return false
            }
        } catch {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: configuration.providerName,
                model: configuration.modelName,
                httpStatus: nil,
                stage: "brainstorm.probe.attempt.failed",
                errorType: "fileWriteFailed",
                detail: "durationSeconds=\(durationSeconds),\(error.localizedDescription)"
            )
            return false
        }
    }

    private func makeSilentWAV(durationSeconds: Int) -> Data {
        let safeDuration = max(0, durationSeconds)
        let sampleRate: Int = 16_000
        let channels: Int = 1
        let bitsPerSample: Int = 16
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let sampleCount = safeDuration * sampleRate
        let pcmDataSize = sampleCount * blockAlign

        var data = Data()
        func appendASCII(_ value: String) {
            data.append(Data(value.utf8))
        }
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { buffer in
                data.append(contentsOf: buffer)
            }
        }

        appendASCII("RIFF")
        appendLE(UInt32(36 + pcmDataSize))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(channels))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(byteRate))
        appendLE(UInt16(blockAlign))
        appendLE(UInt16(bitsPerSample))
        appendASCII("data")
        appendLE(UInt32(pcmDataSize))
        if pcmDataSize > 0 {
            data.append(Data(count: pcmDataSize))
        }
        return data
    }

    private func brainstormProfileKey(
        providerType: ProviderType,
        modelName: String
    ) -> String {
        let normalizedModel = modelName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(providerType.rawValue)|\(normalizedModel)"
    }

    private func startTranscription(for clip: RecordedAudioClip) {
        transcriptionTask?.cancel()

        transcriptionTask = Task { [weak self] in
            guard let self else {
                return
            }

            var resolvedConfiguration: SpeechProviderConfiguration?
            let lane = sessionStore.activeLane
            let traceID = ensureTraceID()

            do {
                guard providerSettingsStore.isConfigurationValid else {
                    throw SpeechTranscriptionError.providerFailure(
                        description: providerSettingsStore.configurationValidationMessage ?? "服务商配置无效。"
                    )
                }

                let configuration = providerSettingsStore.configuration
                resolvedConfiguration = configuration
                guard let provider = providerRegistry.provider(for: configuration.providerType) else {
                    throw SpeechTranscriptionError.providerFailure(description: "当前构建不含所选 provider。")
                }

                let dictionarySnapshot: ASRDictionarySnapshot
                if sessionStore.activeLane == .selectionRewrite {
                    dictionarySnapshot = .empty()
                } else {
                    dictionarySnapshot = asrDictionaryStore.currentSnapshot()
                    notifyIfDictionaryTruncated(snapshot: dictionarySnapshot)
                }

                let apiKey: String
                if configuration.providerType.requiresAPIKey {
                    guard
                        let loaded = try providerSettingsStore.loadAPIKeyForTranscriptionProvider(),
                        !loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        throw SpeechTranscriptionError.missingAPIKey(providerName: configuration.providerName)
                    }
                    apiKey = loaded
                } else {
                    apiKey = ""
                }

                let request = SpeechTranscriptionRequest(
                    clip: clip,
                    lane: sessionStore.activeLane,
                    contextSummary: "lane=\(sessionStore.activeLane.rawValue)",
                    dictionaryTerms: dictionarySnapshot.injectedTerms,
                    dictionaryPromptHint: dictionarySnapshot.promptHintText,
                    dictionaryHotwordText: dictionarySnapshot.hotwordText
                )

                let outcome = try await transcribeWithRetryOnInvalidResponse(
                    provider: provider,
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey,
                    traceID: traceID
                )
                guard !Task.isCancelled else {
                    return
                }

                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                sessionStore.completeTranscription(result: outcome.result)
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: lane,
                    provider: outcome.result.providerName,
                    model: outcome.result.modelName,
                    httpStatus: nil,
                    stage: "asr.success",
                    detail: "attempts=\(outcome.attempts)",
                    audioDuration: clip.duration,
                    transcriptLength: outcome.result.transcript.count
                )
                await processTranscriptionResult(
                    outcome.result,
                    lane: request.lane,
                    audioDurationSeconds: clip.duration
                )
            } catch let failure as ASRTranscriptionFailure {
                guard !Task.isCancelled else {
                    return
                }
                currentDictationTarget = nil
                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                let message = SpeechTranscriptionErrorPresentation.finalErrorMessage(
                    for: failure.error,
                    traceID: traceID,
                    attempts: failure.attempts
                )
                let focusContext = contextDetector.focusedAppContext()
                localHistoryStore.append(
                    SessionHistoryEntry(
                        mode: historyMode(for: lane),
                        appName: focusContext.appName,
                        bundleID: focusContext.bundleID,
                        inputText: "",
                        outputText: nil,
                        transcriptionProvider: resolvedConfiguration?.providerName,
                        transcriptionModel: resolvedConfiguration?.modelName,
                        status: .failed,
                        errorMessage: message,
                        audioDurationSeconds: clip.duration
                    )
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: lane,
                    provider: resolvedConfiguration?.providerName,
                    model: resolvedConfiguration?.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: failure.error),
                    stage: "asr.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: failure.error),
                    detail: message,
                    audioDuration: clip.duration
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: lane,
                    provider: nil,
                    model: nil,
                    httpStatus: nil,
                    stage: "history.failed",
                    errorType: "transcription",
                    detail: message,
                    audioDuration: clip.duration
                )
                sessionStore.fail(message: message)
                currentTraceID = nil
            } catch is CancellationError {
                return
            } catch let speechError as SpeechTranscriptionError {
                guard !Task.isCancelled else {
                    return
                }
                currentDictationTarget = nil
                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                let focusContext = contextDetector.focusedAppContext()
                localHistoryStore.append(
                    SessionHistoryEntry(
                        mode: historyMode(for: sessionStore.activeLane),
                        appName: focusContext.appName,
                        bundleID: focusContext.bundleID,
                        inputText: "",
                        outputText: nil,
                        transcriptionProvider: resolvedConfiguration?.providerName,
                        transcriptionModel: resolvedConfiguration?.modelName,
                        status: .failed,
                        errorMessage: SpeechTranscriptionErrorPresentation.actionableMessage(for: speechError),
                        audioDurationSeconds: clip.duration
                    )
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: lane,
                    provider: resolvedConfiguration?.providerName,
                    model: resolvedConfiguration?.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: speechError),
                    stage: "asr.failed",
                    errorType: SpeechTranscriptionErrorPresentation.errorType(for: speechError),
                    detail: SpeechTranscriptionErrorPresentation.actionableMessage(for: speechError),
                    audioDuration: clip.duration
                )
                sessionStore.fail(message: SpeechTranscriptionErrorPresentation.actionableMessage(for: speechError))
                currentTraceID = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                currentDictationTarget = nil
                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                let message = SpeechTranscriptionErrorPresentation.actionableMessage(
                    for: .providerFailure(description: error.localizedDescription)
                )
                let focusContext = contextDetector.focusedAppContext()
                localHistoryStore.append(
                    SessionHistoryEntry(
                        mode: historyMode(for: sessionStore.activeLane),
                        appName: focusContext.appName,
                        bundleID: focusContext.bundleID,
                        inputText: "",
                        outputText: nil,
                        transcriptionProvider: resolvedConfiguration?.providerName,
                        transcriptionModel: resolvedConfiguration?.modelName,
                        status: .failed,
                        errorMessage: message,
                        audioDurationSeconds: clip.duration
                    )
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: lane,
                    provider: resolvedConfiguration?.providerName,
                    model: resolvedConfiguration?.modelName,
                    httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: message),
                    stage: "asr.failed",
                    errorType: "providerFailure",
                    detail: message,
                    audioDuration: clip.duration
                )
                sessionStore.fail(message: message)
                currentTraceID = nil
            }
        }
    }

    private func notifyIfDictionaryTruncated(snapshot: ASRDictionarySnapshot) {
        guard snapshot.didTruncate else {
            lastDictionaryTruncationSignature = nil
            return
        }

        let signature = dictionarySignature(for: snapshot)
        guard lastDictionaryTruncationSignature != signature else {
            return
        }

        lastDictionaryTruncationSignature = signature
        let toastText = "词典过长，已自动截断后注入（\(snapshot.injectedTerms.count)/\(snapshot.effectiveTerms.count) 条）。"
        toastPresenter?.show(toastText, duration: 2.4)
        NSLog(
            "[ASRDictionary] truncated dictionary injected=%ld effective=%ld maxChars=%ld",
            snapshot.injectedTerms.count,
            snapshot.effectiveTerms.count,
            snapshot.maxCharacters
        )
    }

    private func dictionarySignature(for snapshot: ASRDictionarySnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.maxCharacters)
        hasher.combine(snapshot.effectiveTerms.count)
        for term in snapshot.effectiveTerms {
            hasher.combine(term)
        }
        return hasher.finalize()
    }

    private func processTranscriptionResult(
        _ transcription: SpeechTranscriptionResult,
        lane: InputLane,
        audioDurationSeconds: TimeInterval
    ) async {
        switch lane {
        case .directDictation:
            await outputDictationTranscript(
                transcription,
                audioDurationSeconds: audioDurationSeconds
            )
        case .selectionRewrite:
            await outputSelectionRewrite(
                transcription,
                audioDurationSeconds: audioDurationSeconds
            )
        case .brainstormDiscussion:
            await outputBrainstormContext(
                transcription,
                audioDurationSeconds: audioDurationSeconds
            )
        }
    }

    private func outputDictationTranscript(
        _ transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval
    ) async {
        let traceID = ensureTraceID()
        let writebackTarget = currentDictationTarget
        let focusContext = writebackTarget?.focusContext ?? contextDetector.focusedAppContext()
        let writebackWarmupTask = Task { [weak self] in
            guard
                let self,
                let warmableCoordinator = self.textOutputCoordinator as? AccessibilityTextOutputCoordinator
            else {
                return
            }
            await warmableCoordinator.prepareForWrite(
                preferredTarget: writebackTarget?.snapshot,
                fallbackFocusContext: focusContext
            )
        }
        let scenePolicy = effectiveScenePolicy(for: focusContext)
        let skillApplyResult = skillRuleStore.applyDictation(
            transcription.transcript,
            outputBias: .neutral
        )
        let localProcessedText = skillApplyResult.text
        let postProcessResult = await postProcessDictationIfNeeded(
            text: localProcessedText,
            focusContext: focusContext,
            appPrompt: scenePolicy.appPrompt
        )
        _ = await writebackWarmupTask.value
        let finalText = postProcessResult.text
        let finalTranscription = SpeechTranscriptionResult(
            providerType: transcription.providerType,
            providerName: transcription.providerName,
            modelName: transcription.modelName,
            transcript: finalText
        )
        let appliedSkills = mergedSkills(
            lhs: skillApplyResult.appliedSkills,
            rhs: postProcessResult.appliedSkills
        )

        let request = TextOutputRequest(
            text: finalTranscription.transcript,
            operation: .insertText,
            focusContext: focusContext,
            preferredTarget: writebackTarget?.snapshot
        )

        sessionStore.markInserting(
            transcription: finalTranscription,
            focusContext: focusContext
        )

        do {
            let outputResult = try await textOutputCoordinator.write(request: request)
            sessionStore.completeInsertion(
                outputResult: outputResult,
                note: postProcessResult.nonBlockingNotice
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .dictation,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: finalTranscription.transcript,
                    transcriptionProvider: finalTranscription.providerName,
                    transcriptionModel: finalTranscription.modelName,
                    outputPath: outputResult.path,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: finalTranscription.providerName,
                model: finalTranscription.modelName,
                httpStatus: nil,
                stage: "write.success",
                detail: "path=\(outputResult.path.rawValue)",
                audioDuration: audioDurationSeconds,
                transcriptLength: finalTranscription.transcript.count
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "history.success",
                audioDuration: audioDurationSeconds,
                transcriptLength: finalTranscription.transcript.count
            )
            currentDictationTarget = nil
            currentTraceID = nil
        } catch let outputError as TextOutputError {
            let message = actionableOutputMessage(for: outputError, focusContext: focusContext)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .dictation,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: nil,
                    transcriptionProvider: finalTranscription.providerName,
                    transcriptionModel: finalTranscription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: finalTranscription.providerName,
                model: finalTranscription.modelName,
                httpStatus: nil,
                stage: "write.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "history.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            currentDictationTarget = nil
            sessionStore.fail(message: message)
            currentTraceID = nil
        } catch {
            let message = actionableOutputMessage(
                for: .accessibilityPathFailed(reason: error.localizedDescription),
                focusContext: focusContext
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .dictation,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: nil,
                    transcriptionProvider: finalTranscription.providerName,
                    transcriptionModel: finalTranscription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: finalTranscription.providerName,
                model: finalTranscription.modelName,
                httpStatus: nil,
                stage: "write.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .directDictation,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "history.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            currentDictationTarget = nil
            sessionStore.fail(message: message)
            currentTraceID = nil
        }
    }

    private func outputBrainstormContext(
        _ transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval
    ) async {
        let traceID = ensureTraceID()
        let writebackTarget = currentDictationTarget
        let focusContext = writebackTarget?.focusContext ?? contextDetector.focusedAppContext()
        let scenePolicy = effectiveScenePolicy(for: focusContext)
        let normalizedAppPrompt = scenePolicy.appPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userSystemPrompt = skillRuleStore.activeSystemPrompt()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localApplyResult = skillRuleStore.applyDictation(
            transcription.transcript,
            outputBias: .neutral
        )
        let normalizedTranscript = localApplyResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let inputForCompose = normalizedTranscript.isEmpty
            ? transcription.transcript
            : normalizedTranscript

        let writebackWarmupTask = Task { [weak self] in
            guard
                let self,
                let warmableCoordinator = self.textOutputCoordinator as? AccessibilityTextOutputCoordinator
            else {
                return
            }
            await warmableCoordinator.prepareForWrite(
                preferredTarget: writebackTarget?.snapshot,
                fallbackFocusContext: focusContext
            )
        }

        let composeOutcome = await composeBrainstormContext(
            transcript: inputForCompose,
            focusContext: focusContext,
            appPrompt: normalizedAppPrompt.isEmpty ? nil : normalizedAppPrompt,
            userSystemPrompt: userSystemPrompt.isEmpty ? nil : userSystemPrompt,
            traceID: traceID
        )
        _ = await writebackWarmupTask.value

        let finalTranscription = SpeechTranscriptionResult(
            providerType: transcription.providerType,
            providerName: transcription.providerName,
            modelName: transcription.modelName,
            transcript: composeOutcome.summaryText
        )
        let appliedSkills = mergedSkills(
            lhs: localApplyResult.appliedSkills,
            rhs: composeOutcome.appliedSkills
        )

        let request = TextOutputRequest(
            text: finalTranscription.transcript,
            operation: .insertText,
            focusContext: focusContext,
            preferredTarget: writebackTarget?.snapshot
        )

        sessionStore.markInserting(
            transcription: finalTranscription,
            focusContext: focusContext
        )

        do {
            let outputResult = try await textOutputCoordinator.write(request: request)
            sessionStore.completeInsertion(
                outputResult: outputResult,
                note: composeOutcome.nonBlockingNotice
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .brainstorm,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: finalTranscription.transcript,
                    brainstormDialogueText: composeOutcome.dialogueText,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: composeOutcome.rewriteProvider,
                    rewriteModel: composeOutcome.rewriteModel,
                    outputPath: outputResult.path,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: composeOutcome.rewriteProvider ?? transcription.providerName,
                model: composeOutcome.rewriteModel ?? transcription.modelName,
                httpStatus: nil,
                stage: "write.success",
                detail: "path=\(outputResult.path.rawValue)",
                audioDuration: audioDurationSeconds,
                transcriptLength: finalTranscription.transcript.count,
                tokenBudget: composeOutcome.tokenBudget
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "history.success",
                audioDuration: audioDurationSeconds,
                transcriptLength: finalTranscription.transcript.count,
                tokenBudget: composeOutcome.tokenBudget
            )
            currentDictationTarget = nil
            currentTraceID = nil
        } catch let outputError as TextOutputError {
            let message = actionableOutputMessage(for: outputError, focusContext: focusContext)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .brainstorm,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: nil,
                    brainstormDialogueText: composeOutcome.dialogueText,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: composeOutcome.rewriteProvider,
                    rewriteModel: composeOutcome.rewriteModel,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: composeOutcome.rewriteProvider ?? transcription.providerName,
                model: composeOutcome.rewriteModel ?? transcription.modelName,
                httpStatus: nil,
                stage: "write.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds,
                tokenBudget: composeOutcome.tokenBudget
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "history.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds,
                tokenBudget: composeOutcome.tokenBudget
            )
            currentDictationTarget = nil
            sessionStore.fail(message: message)
            currentTraceID = nil
        } catch {
            let message = actionableOutputMessage(
                for: .accessibilityPathFailed(reason: error.localizedDescription),
                focusContext: focusContext
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .brainstorm,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: nil,
                    brainstormDialogueText: composeOutcome.dialogueText,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: composeOutcome.rewriteProvider,
                    rewriteModel: composeOutcome.rewriteModel,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: composeOutcome.rewriteProvider ?? transcription.providerName,
                model: composeOutcome.rewriteModel ?? transcription.modelName,
                httpStatus: nil,
                stage: "write.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds,
                tokenBudget: composeOutcome.tokenBudget
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "history.failed",
                errorType: "textOutput",
                detail: message,
                audioDuration: audioDurationSeconds,
                tokenBudget: composeOutcome.tokenBudget
            )
            currentDictationTarget = nil
            sessionStore.fail(message: message)
            currentTraceID = nil
        }
    }

    private func composeBrainstormContext(
        transcript: String,
        focusContext: FocusedAppContext,
        appPrompt: String?,
        userSystemPrompt: String?,
        traceID: String
    ) async -> BrainstormComposeOutcome {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: nil,
                model: nil,
                httpStatus: nil,
                stage: "brainstorm.compose.skipped",
                errorType: "emptyTranscript"
            )
            return makeFallbackBrainstormOutcome(
                transcript: "",
                notice: "转写文本为空，已给出最小模板。"
            )
        }
        let tokenBudget = LLMBrainstormContextComposer.dynamicTokenBudget(for: normalizedTranscript)

        let normalizedSystemPrompt = userSystemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAppPrompt = appPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        speechPipelineLogger.log(
            traceID: traceID,
            lane: .brainstormDiscussion,
            provider: providerSettingsStore.rewriteConfiguration.providerName,
            model: providerSettingsStore.rewriteConfiguration.modelName,
            httpStatus: nil,
            stage: "brainstorm.compose.start",
            transcriptLength: normalizedTranscript.count,
            tokenBudget: tokenBudget
        )

        guard providerSettingsStore.isRewriteConfigurationValid else {
            let message = providerSettingsStore.rewriteConfigurationValidationMessage
                ?? "文本模型配置无效。"
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "brainstorm.compose.fallback",
                errorType: "invalidRewriteConfiguration",
                detail: message,
                tokenBudget: tokenBudget
            )
            return makeFallbackBrainstormOutcome(
                transcript: normalizedTranscript,
                notice: "文本模型暂不可用（\(message)），已给出基础模板。",
                tokenBudget: tokenBudget
            )
        }

        guard
            let loadedKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider(),
            !loadedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "brainstorm.compose.fallback",
                errorType: "missingAPIKey",
                tokenBudget: tokenBudget
            )
            return makeFallbackBrainstormOutcome(
                transcript: normalizedTranscript,
                notice: "文本模型密钥不可用，已给出基础模板。",
                tokenBudget: tokenBudget
            )
        }

        var modelAppliedSkills: [SkillRuleID] = []
        if !normalizedAppPrompt.isEmpty {
            modelAppliedSkills.append(.appPreferenceBoost)
        }
        if !normalizedSystemPrompt.isEmpty {
            modelAppliedSkills.append(.systemPrompt)
        }

        let apiKey = loadedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await brainstormContextComposer.compose(
                request: BrainstormContextComposeRequest(
                    transcript: normalizedTranscript,
                    focusContext: focusContext,
                    appPrompt: normalizedAppPrompt.isEmpty ? nil : normalizedAppPrompt,
                    userSystemPrompt: normalizedSystemPrompt.isEmpty ? nil : normalizedSystemPrompt
                ),
                configuration: providerSettingsStore.rewriteConfiguration,
                apiKey: apiKey
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: result.providerName,
                model: result.modelName,
                httpStatus: nil,
                stage: "brainstorm.compose.success",
                transcriptLength: result.summaryText.count,
                tokenBudget: tokenBudget
            )
            return BrainstormComposeOutcome(
                summaryText: result.summaryText,
                dialogueText: result.dialogueText,
                rewriteProvider: result.providerName,
                rewriteModel: result.modelName,
                tokenBudget: tokenBudget,
                appliedSkills: modelAppliedSkills,
                nonBlockingNotice: nil
            )
        } catch {
            let message = error.localizedDescription
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .brainstormDiscussion,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: SpeechTranscriptionErrorPresentation.httpStatus(from: message),
                stage: "brainstorm.compose.fallback",
                errorType: "composeFailed",
                detail: message,
                tokenBudget: tokenBudget
            )
            return makeFallbackBrainstormOutcome(
                transcript: normalizedTranscript,
                notice: "上下文整理失败，已回退到基础模板。",
                tokenBudget: tokenBudget
            )
        }
    }

    private func makeFallbackBrainstormOutcome(
        transcript: String,
        notice: String,
        tokenBudget: Int? = nil
    ) -> BrainstormComposeOutcome {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrainstormComposeOutcome(
            summaryText: BrainstormFallbackComposer.summary(for: normalized),
            dialogueText: BrainstormFallbackComposer.dialogue(for: normalized),
            rewriteProvider: nil,
            rewriteModel: nil,
            tokenBudget: tokenBudget,
            appliedSkills: [],
            nonBlockingNotice: notice
        )
    }

    private func outputSelectionRewrite(
        _ transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval
    ) async {
        let traceID = ensureTraceID()
        let rawInstruction = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialFocusContext = contextDetector.focusedAppContext()
        let seedSelectionSnapshot: FocusedSelectionSnapshot? = nil
        let enabledFeatures = magicianFeatureToggleStore.enabledFeatures
        let defaultRuntimeVersion = v4RuntimeSwitchStore.defaultRuntimeVersion
        let runtimeEvents: [MagicianAgentRuntimeEvent] = []

        let fallbackFocusContextForPreprocess: FocusedAppContext = {
            if let seedSelectionSnapshot {
                return seedSelectionSnapshot.focusContext
            }
            let selfBundleID = Bundle.main.bundleIdentifier
            if
                initialFocusContext.bundleID == selfBundleID,
                let externalTarget = lastExternalDictationTarget
            {
                return externalTarget.focusContext
            }
            return initialFocusContext
        }()

        let commandPreprocessResult = await MagicianCommandSemanticPreprocessor(
            providerSettingsStore: providerSettingsStore,
            rewriteProviderRegistry: rewriteProviderRegistry,
            skillRuleStore: skillRuleStore,
            asrDictionaryStore: asrDictionaryStore
        ).preprocess(
            rawCommand: rawInstruction,
            focusContext: fallbackFocusContextForPreprocess
        )
        let spokenInstruction = commandPreprocessResult.command
        let commandAppliedSkills = commandPreprocessResult.appliedSkills
        let seedSelectionText = ""

        guard !spokenInstruction.isEmpty else {
            let message = "改写指令为空，请重试并说出明确命令。"
            let failureTrace = magicianFailureExecutionTraceText(
                traceID: traceID,
                command: spokenInstruction,
                stage: "input_validation",
                errorCode: MagicianErrorCode.intentParseFailed.rawValue,
                errorMessage: message,
                debugMessage: "spoken instruction empty after preprocessing",
                recoverAction: "retry_command",
                focusContext: fallbackFocusContextForPreprocess,
                runtimeEvents: runtimeEvents
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContextForPreprocess.appName,
                    bundleID: fallbackFocusContextForPreprocess.bundleID,
                    inputText: seedSelectionText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    magicianRuntimeVersion: defaultRuntimeVersion,
                    magicianExecutionTrace: failureTrace,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: commandAppliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let hasTimeMachineIntent = V4RulePlannerHeuristics.looksLikeTimeMachineIntent(spokenInstruction)

        guard !enabledFeatures.isEmpty || hasTimeMachineIntent else {
            let message = seedSelectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "无选中场景当前没有可用能力，请先在魔术先生页面打开权限开关。"
                : "当前没有可用能力，请先在魔术先生页面打开权限开关。"
            let failureTrace = magicianFailureExecutionTraceText(
                traceID: traceID,
                command: spokenInstruction,
                stage: "capability_check",
                errorCode: MagicianErrorCode.intentParseFailed.rawValue,
                errorMessage: message,
                debugMessage: "enabled feature set empty",
                recoverAction: nil,
                focusContext: fallbackFocusContextForPreprocess,
                runtimeEvents: runtimeEvents
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContextForPreprocess.appName,
                    bundleID: fallbackFocusContextForPreprocess.bundleID,
                    inputText: seedSelectionText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    magicianRuntimeVersion: defaultRuntimeVersion,
                    magicianExecutionTrace: failureTrace,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: commandAppliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let laneRouterStartedAt = Date()
        let initialLaneDecision = await magicianLaneRouter.decide(
            command: spokenInstruction,
            selectionSnapshot: seedSelectionSnapshot,
            enabledFeatures: enabledFeatures
        )
        let laneRouterEndedAt = Date()
        let routerLLMMilliseconds = Int(laneRouterEndedAt.timeIntervalSince(laneRouterStartedAt) * 1000)
        let selectionSeedAfterRoute: FocusedSelectionSnapshot? = {
            guard initialLaneDecision.selectionMode != .none else {
                return nil
            }
            return normalizedSelectionSnapshot(textOutputCoordinator.currentSelectionSnapshot())
        }()
        let selectionSnapshot = await resolveMagicianSelectionSnapshot(
            mode: initialLaneDecision.selectionMode,
            seedSnapshot: selectionSeedAfterRoute
        )
        if abortIfSessionCancelled() {
            return
        }

        let selectionText = selectionSnapshot?.selectedText ?? ""
        let selectedFiles = captureFinderSelectedFiles()
        let fallbackFocusContext: FocusedAppContext = {
            if let selectionSnapshot {
                return selectionSnapshot.focusContext
            }
            return fallbackFocusContextForPreprocess
        }()

        if
            initialLaneDecision.selectionMode == .required,
            selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let message = "请先选中一段文本，再说要执行的动作。"
            let failureTrace = magicianFailureExecutionTraceText(
                traceID: traceID,
                command: spokenInstruction,
                stage: "selection_required",
                errorCode: MagicianErrorCode.intentParseFailed.rawValue,
                errorMessage: message,
                debugMessage: "selection required but no live selection snapshot",
                recoverAction: "retry_command",
                focusContext: fallbackFocusContext,
                runtimeEvents: runtimeEvents
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContext.appName,
                    bundleID: fallbackFocusContext.bundleID,
                    inputText: "",
                    outputText: nil,
                    instructionText: spokenInstruction,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    magicianRuntimeVersion: defaultRuntimeVersion,
                    magicianExecutionTrace: failureTrace,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: commandAppliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let refreshedLaneDecision: MagicianLaneDecision
        if
            initialLaneDecision.selectionMode != .none,
            selectionSeedAfterRoute?.selectedText != selectionSnapshot?.selectedText
        {
            refreshedLaneDecision = await magicianLaneRouter.decide(
                command: spokenInstruction,
                selectionSnapshot: selectionSnapshot,
                enabledFeatures: enabledFeatures
            )
        } else {
            refreshedLaneDecision = initialLaneDecision
        }

        if refreshedLaneDecision.executionPath == .musicFast {
            await executeMusicFastPath(
                traceID: traceID,
                spokenInstruction: spokenInstruction,
                focusContext: fallbackFocusContext,
                selectionText: selectionText,
                laneDecision: refreshedLaneDecision,
                transcription: transcription,
                audioDurationSeconds: audioDurationSeconds,
                appliedSkills: commandAppliedSkills,
                routerLLMMilliseconds: routerLLMMilliseconds
            )
            return
        }

        let runtimeRoute = v4RuntimeSwitchStore.route(for: refreshedLaneDecision)
        switch runtimeRoute {
        case .v4:
            await executeSelectionRewriteWithV4(
                traceID: traceID,
                spokenInstruction: spokenInstruction,
                selectionSnapshot: selectionSnapshot,
                selectedFiles: selectedFiles,
                fallbackFocusContext: fallbackFocusContext,
                selectionText: selectionText,
                enabledFeatures: enabledFeatures,
                transcription: transcription,
                audioDurationSeconds: audioDurationSeconds,
                appliedSkills: commandAppliedSkills
            )
        case .legacyNative, .legacyAgent:
            let legacyRuntimeEvents = LockedMagicianRuntimeEventBuffer()
            await executeSelectionRewriteWithLegacyRuntime(
                traceID: traceID,
                spokenInstruction: spokenInstruction,
                selectionSnapshot: selectionSnapshot,
                fallbackFocusContext: fallbackFocusContext,
                selectionText: selectionText,
                transcription: transcription,
                audioDurationSeconds: audioDurationSeconds,
                appliedSkills: commandAppliedSkills,
                runtimeRoute: runtimeRoute,
                runtimeEvents: legacyRuntimeEvents,
                enabledFeatures: enabledFeatures
            )
        }
    }

    private func handleMagicianRuntimeEvent(_ event: MagicianAgentRuntimeEvent) {
        switch event.state {
        case .queued, .understanding, .probingCapabilities, .resolvingTargets, .planning, .executingStep, .observing, .verifying, .retryingStep, .replanning:
            sessionStore.markRewriting(
                actionLabel: event.message,
                stage: .toolAction,
                progressHint: event.progressHint
            )
        case .waitingForUser:
            sessionStore.fail(message: event.message)
        case .failed, .completed:
            break
        }
    }

    private func executeMusicFastPath(
        traceID: String,
        spokenInstruction: String,
        focusContext: FocusedAppContext,
        selectionText: String,
        laneDecision: MagicianLaneDecision,
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: Double,
        appliedSkills: [SkillRuleID],
        routerLLMMilliseconds: Int
    ) async {
        guard let intent = laneDecision.normalizedIntent else {
            let message = "音乐命令解析失败，请重试。"
            let executionTrace = musicFastExecutionTraceText(
                traceID: traceID,
                command: spokenInstruction,
                selectionPresent: false,
                routerLLMMilliseconds: routerLLMMilliseconds,
                toolMilliseconds: nil,
                verifyMilliseconds: nil,
                outcome: nil,
                errorCode: V4FailureCode.invalidRequest.rawValue,
                errorMessage: message
            )
            let entryID = UUID()
            localHistoryStore.append(
                SessionHistoryEntry(
                    id: entryID,
                    mode: .selectionRewrite,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: selectionText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianRuntimeVersion: 4,
                    magicianExecutionTrace: executionTrace,
                    magicianExecutionInterpretation: nil,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let toolStartedAt = Date()
        let outcome = await musicFastExecutor.execute(
            MusicFastRequest(
                traceID: traceID,
                command: spokenInstruction,
                intent: intent,
                query: laneDecision.normalizedQuery,
                focusContext: focusContext
            )
        )
        let toolFinishedAt = Date()
        let toolMilliseconds = Int(toolFinishedAt.timeIntervalSince(toolStartedAt) * 1000)
        let verifyStartedAt = Date()
        let verifyMilliseconds = Int(Date().timeIntervalSince(verifyStartedAt) * 1000)
        let endToEndMilliseconds = Int(toolFinishedAt.timeIntervalSince(toolStartedAt) * 1000) + routerLLMMilliseconds
        let executionTrace = musicFastExecutionTraceText(
            traceID: traceID,
            command: spokenInstruction,
            selectionPresent: false,
            routerLLMMilliseconds: routerLLMMilliseconds,
            toolMilliseconds: toolMilliseconds,
            verifyMilliseconds: verifyMilliseconds,
            outcome: outcome,
            errorCode: outcome.failureCode?.rawValue,
            errorMessage: outcome.status == .failed ? outcome.message : nil,
            endToEndMilliseconds: endToEndMilliseconds
        )
        let entryID = UUID()
        localHistoryStore.append(
            SessionHistoryEntry(
                id: entryID,
                mode: .selectionRewrite,
                appName: focusContext.appName,
                bundleID: focusContext.bundleID,
                inputText: selectionText,
                outputText: outcome.outputText,
                instructionText: spokenInstruction,
                magicianFeatureID: .music,
                displayText: outcome.message,
                transcriptionProvider: transcription.providerName,
                transcriptionModel: transcription.modelName,
                magicianRuntimeVersion: 4,
                magicianEvidenceSummary: outcome.evidenceSummary,
                magicianExecutionTrace: executionTrace,
                magicianExecutionInterpretation: nil,
                status: outcome.status,
                errorMessage: outcome.status == .failed ? outcome.message : nil,
                audioDurationSeconds: audioDurationSeconds,
                appliedSkills: appliedSkills
            )
        )
        Task { [weak self] in
            guard let self else {
                return
            }
            let interpretation = await self.musicExecutionInterpreter.interpret(
                MusicExecutionInterpretationRequest(
                    command: spokenInstruction,
                    status: outcome.status,
                    outputText: outcome.outputText,
                    evidenceSummary: outcome.evidenceSummary,
                    rawExecutionTrace: executionTrace
                )
            )
            await MainActor.run {
                self.localHistoryStore.updateMagicianExecutionInterpretation(
                    entryID: entryID,
                    interpretation: interpretation
                )
            }
        }

        let telemetryEvent: WorkflowTelemetryEvent = {
            if outcome.status == .success {
                return WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: nil,
                    model: nil,
                    event: .done,
                    detail: spokenInstruction,
                    audioDuration: audioDurationSeconds,
                    transcriptLength: outcome.outputText?.count,
                    stepCount: 1
                )
            }
            return WorkflowTelemetryEvent(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: nil,
                model: nil,
                event: .failed,
                errorType: outcome.failureCode?.rawValue ?? V4FailureCode.toolExecutionFailed.rawValue,
                detail: outcome.message,
                audioDuration: audioDurationSeconds
            )
        }()
        workflowTelemetryReporter.record(telemetryEvent)

        if outcome.status == .success {
            sessionStore.completeAction(statusMessage: "\(outcome.message)（执行解读会作为额外任务写入记忆。）")
        } else {
            sessionStore.fail(message: "\(outcome.message)（执行解读会作为额外任务写入记忆。）")
        }
        currentTraceID = nil
    }

    private func executeSelectionRewriteWithV4(
        traceID: String,
        spokenInstruction: String,
        selectionSnapshot: FocusedSelectionSnapshot?,
        selectedFiles: [V4SelectedFileInput],
        fallbackFocusContext: FocusedAppContext,
        selectionText: String,
        enabledFeatures: Set<MagicianFeatureID>,
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: Double,
        appliedSkills: [SkillRuleID]
    ) async {
        let selectionContext = selectionSnapshot?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelInputText = inputTextForV4Planner(
            command: spokenInstruction,
            selectionText: selectionContext
        )
        let goalSummary = goalSummaryForV4Planner(
            command: spokenInstruction,
            selectionText: selectionContext
        )
        let request = V4RunRequest(
            traceID: V4TraceID(rawValue: traceID),
            lane: .selectionRewrite,
            goalSummary: goalSummary,
            inputText: modelInputText,
            appName: fallbackFocusContext.appName,
            bundleID: fallbackFocusContext.bundleID,
            selectionText: selectionSnapshot?.selectedText,
            selectedFiles: selectedFiles,
            enabledFeatureIDs: Set(enabledFeatures.map(\.rawValue))
        )
        let plannerRequest = v4MemoryPlannerInputAdapter.adapt(
            request: request,
            historyEntries: localHistoryStore.entries
        )
        let eventBuffer = LockedV4RuntimeEventBuffer()

        v4SessionStoreBridge.applyRunStart(request: plannerRequest, to: sessionStore)

        do {
            let outcome = try await v4MagicianRuntime.run(
                request: plannerRequest,
                onEvent: { [weak self] event in
                    eventBuffer.append(event)
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        self.v4SessionStoreBridge.applyRuntimeEvent(event, to: self.sessionStore)
                    }
                }
            )
            if abortIfSessionCancelled() {
                return
            }

            let historyStatus: SessionHistoryStatus = outcome.status == V4RunStatus.completed ? .success : .failed
            let runtimeEvents = eventBuffer.snapshot()
            let resolvedAppliedSkills = mergedSkills(
                lhs: appliedSkills,
                rhs: plannerRequest.promptStack?.appliedSkillRuleIDs ?? []
            )
            localHistoryStore.append(
                v4HistoryBridge.makeHistoryEntry(
                    from: plannerRequest,
                    outcome: outcome,
                    status: historyStatus,
                    focusContext: fallbackFocusContext,
                    selectionText: selectionText,
                    transcription: transcription,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: resolvedAppliedSkills,
                    runtimeEvents: runtimeEvents
                )
            )
            recordV4Telemetry(
                traceID: traceID,
                outcome: outcome,
                historyStatus: historyStatus,
                audioDurationSeconds: audioDurationSeconds
            )
            v4SessionStoreBridge.applyRunOutcome(outcome, to: sessionStore)
            if let statusMessage = await v4OutcomeDeliveryMessage(
                outcome: outcome,
                selectionSnapshot: selectionSnapshot,
                fallbackFocusContext: fallbackFocusContext
            ) {
                sessionStore.completeAction(statusMessage: statusMessage)
            }
            currentTraceID = nil
        } catch {
            if abortIfSessionCancelled() {
                return
            }

            if let magicianError = error as? MagicianError {
                handleMagicianRecoverAction(magicianError.recoverAction)
            }

            let outcome = makeV4FailureOutcome(
                request: plannerRequest,
                error: error,
                runtimeEvents: eventBuffer.snapshot()
            )
            let resolvedAppliedSkills = mergedSkills(
                lhs: appliedSkills,
                rhs: plannerRequest.promptStack?.appliedSkillRuleIDs ?? []
            )
            localHistoryStore.append(
                v4HistoryBridge.makeHistoryEntry(
                    from: plannerRequest,
                    outcome: outcome,
                    status: .failed,
                    focusContext: fallbackFocusContext,
                    selectionText: selectionText,
                    transcription: transcription,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: resolvedAppliedSkills,
                    runtimeEvents: eventBuffer.snapshot()
                )
            )
            recordV4Telemetry(
                traceID: traceID,
                outcome: outcome,
                historyStatus: .failed,
                audioDurationSeconds: audioDurationSeconds
            )
            v4SessionStoreBridge.applyRunOutcome(outcome, to: sessionStore)
            currentTraceID = nil
        }
    }

    private func v4OutcomeDeliveryMessage(
        outcome: V4RunOutcome,
        selectionSnapshot: FocusedSelectionSnapshot?,
        fallbackFocusContext: FocusedAppContext
    ) async -> String? {
        guard outcome.status == .completed else {
            return nil
        }
        guard let lastTool = outcome.stepRecords.last?.toolName else {
            return nil
        }

        if lastTool == "text.transform" {
            return await v4TextWritebackMessage(
                for: outcome,
                selectionSnapshot: selectionSnapshot,
                fallbackFocusContext: fallbackFocusContext
            )
        }

        let transformedOutput = outcome.stepRecords.reversed()
            .first(where: { $0.toolName == "text.transform" })?
            .outputSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTransformedOutput: String? = {
            guard let transformedOutput, !transformedOutput.isEmpty else {
                return nil
            }
            return transformedOutput
        }()
        let finalOutput = outcome.finalOutputText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFinalOutput: String? = {
            guard let finalOutput, !finalOutput.isEmpty else {
                return nil
            }
            return finalOutput
        }()
        let mirrorText = normalizedTransformedOutput ?? normalizedFinalOutput

        if let mirrorText {
            _ = persistTextToClipboard(mirrorText)
        }

        switch lastTool {
        case "md.pipeline":
            return "本地 md 文档已创建，结果文本已同步到剪贴板。"
        case "apple.notes.create":
            return "备忘录操作已完成，结果文本已同步到剪贴板。"
        case "apple.calendar.create":
            return "日程操作已完成，结果文本已同步到剪贴板。"
        case "apple.mail.compose":
            return "邮件操作已完成，结果文本已同步到剪贴板。"
        default:
            return mirrorText == nil ? nil : "已完成当前任务，结果已同步到剪贴板。"
        }
    }

    private func inputTextForV4Planner(
        command: String,
        selectionText: String?
    ) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectionText, !selectionText.isEmpty else {
            return trimmedCommand
        }
        return """
        \(trimmedCommand)

        [SELECTED_TEXT]
        \(selectionText)
        [/SELECTED_TEXT]
        """
    }

    private func captureFinderSelectedFiles() -> [V4SelectedFileInput] {
        let script = """
        tell application "Finder"
            set sel to selection as alias list
            set outText to ""
            repeat with itemAlias in sel
                set outText to outText & POSIX path of itemAlias & linefeed
            end repeat
            return outText
        end tell
        """
        guard let appleScript = NSAppleScript(source: script) else {
            return []
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo != nil {
            return []
        }
        guard let raw = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return []
        }

        let allowedTypes: Set<String> = ["pdf", "docx", "xlsx", "xls", "csv"]
        return raw
            .components(separatedBy: .newlines)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .map { path in
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()
                return V4SelectedFileInput(
                    path: path,
                    name: url.lastPathComponent,
                    fileType: ext
                )
            }
            .filter { allowedTypes.contains($0.fileType) }
    }

    private func goalSummaryForV4Planner(
        command: String,
        selectionText: String?
    ) -> String {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectionText, !selectionText.isEmpty else {
            return trimmedCommand
        }
        return "\(trimmedCommand)（基于选中文本）"
    }

    private func v4TextWritebackMessage(
        for outcome: V4RunOutcome,
        selectionSnapshot: FocusedSelectionSnapshot?,
        fallbackFocusContext: FocusedAppContext
    ) async -> String? {
        guard outcome.status == .completed else {
            return nil
        }
        guard outcome.stepRecords.last?.toolName == "text.transform" else {
            return nil
        }
        guard let finalText = outcome.finalOutputText?.trimmingCharacters(in: .whitespacesAndNewlines), !finalText.isEmpty else {
            return nil
        }

        let hasSelection = !(selectionSnapshot?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let request = TextOutputRequest(
            text: finalText,
            operation: hasSelection ? .replaceSelectedText : .insertText,
            focusContext: fallbackFocusContext,
            preferredTarget: resolvedMagicianWritebackTarget(
                selectionSnapshot: selectionSnapshot,
                fallbackFocusContext: fallbackFocusContext
            )
        )

        do {
            let result = try await textOutputCoordinator.write(request: request)
            if result.didInsertIntoEditor {
                _ = persistTextToClipboard(finalText)
                return "文字处理已完成，结果已写入目标位置，并同步到剪贴板。"
            }
            _ = persistTextToClipboard(finalText)
            return "文字处理已完成，结果已放到剪贴板。"
        } catch {
            if persistTextToClipboard(finalText) {
                return "文字处理已完成，结果已放到剪贴板。"
            }
            return nil
        }
    }

    private func resolvedMagicianWritebackTarget(
        selectionSnapshot: FocusedSelectionSnapshot?,
        fallbackFocusContext: FocusedAppContext
    ) -> WritebackTargetSnapshot? {
        let selfBundleID = Bundle.main.bundleIdentifier
        let targetContext = selectionSnapshot?.focusContext ?? fallbackFocusContext

        guard !targetContext.bundleID.isEmpty else {
            return nil
        }
        if targetContext.bundleID == selfBundleID, !targetContext.hasEditableTarget {
            return nil
        }

        let targetApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: targetContext.bundleID)
            .first
        return WritebackTargetSnapshot(
            appName: targetContext.appName,
            bundleID: targetContext.bundleID,
            processIdentifier: targetApplication?.processIdentifier
        )
    }

    private func persistTextToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private func executeSelectionRewriteWithLegacyRuntime(
        traceID: String,
        spokenInstruction: String,
        selectionSnapshot: FocusedSelectionSnapshot?,
        fallbackFocusContext: FocusedAppContext,
        selectionText: String,
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: Double,
        appliedSkills: [SkillRuleID],
        runtimeRoute: V4RuntimeRoute,
        runtimeEvents: LockedMagicianRuntimeEventBuffer,
        enabledFeatures: Set<MagicianFeatureID>
    ) async {
        let runtimeRequest = MagicianAgentRequest(
            traceID: traceID,
            command: spokenInstruction,
            selectionSnapshot: selectionSnapshot,
            focusContext: fallbackFocusContext,
            enabledFeatures: enabledFeatures
        )

        guard let selectedRuntime = legacyRuntimeResolver.runtime(for: runtimeRoute) else {
            return
        }

        do {
            let outcome = try await selectedRuntime.run(
                request: runtimeRequest,
                onEvent: { [weak self] event in
                    runtimeEvents.append(event)
                    self?.handleMagicianRuntimeEvent(event)
                }
            )
            if abortIfSessionCancelled() {
                return
            }
            let executionTrace = magicianExecutionTraceText(
                command: spokenInstruction,
                outcome: outcome,
                runtimeEvents: runtimeEvents.snapshot()
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContext.appName,
                    bundleID: fallbackFocusContext.bundleID,
                    inputText: selectionText,
                    outputText: outcome.finalOutputText,
                    instructionText: spokenInstruction,
                    magicianFeatureID: outcome.steps.last?.featureID,
                    displayText: outcome.displayText,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    magicianRuntimeVersion: runtimeRoute.runtimeVersion,
                    magicianSessionID: outcome.sessionID,
                    magicianRunID: outcome.runID,
                    magicianGoalSummary: outcome.goalSummary,
                    magicianStepSummaries: outcome.steps.map { "\($0.featureID.rawValue):\($0.userMessage)" },
                    magicianEvidenceSummary: outcome.evidenceSummary,
                    magicianExecutionTrace: executionTrace,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: nil,
                    model: nil,
                    event: .done,
                    detail: outcome.goalSummary,
                    audioDuration: audioDurationSeconds,
                    transcriptLength: outcome.finalOutputText?.count,
                    stepCount: outcome.steps.count
                )
            )
            sessionStore.completeAction(statusMessage: outcome.finalStatusMessage)
            currentTraceID = nil
        } catch let magicianError as MagicianError {
            if abortIfSessionCancelled() {
                return
            }
            let failureTrace = magicianFailureExecutionTraceText(
                traceID: traceID,
                command: spokenInstruction,
                stage: "runtime",
                errorCode: magicianError.code.rawValue,
                errorMessage: magicianError.userMessage,
                debugMessage: magicianError.debugMessage,
                recoverAction: magicianError.recoverAction,
                focusContext: fallbackFocusContext,
                runtimeEvents: runtimeEvents.snapshot()
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContext.appName,
                    bundleID: fallbackFocusContext.bundleID,
                    inputText: selectionText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    magicianRuntimeVersion: runtimeRoute.runtimeVersion,
                    magicianExecutionTrace: failureTrace,
                    status: .failed,
                    errorMessage: magicianError.userMessage,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: nil,
                    model: nil,
                    event: .failed,
                    errorType: magicianError.code.rawValue,
                    detail: magicianError.debugMessage ?? magicianError.userMessage,
                    audioDuration: audioDurationSeconds
                )
            )
            handleMagicianRecoverAction(magicianError.recoverAction)
            sessionStore.fail(message: magicianError.userMessage)
            currentTraceID = nil
        } catch {
            if abortIfSessionCancelled() {
                return
            }
            let message = "魔术先生执行失败：\(error.localizedDescription)"
            let failureTrace = magicianFailureExecutionTraceText(
                traceID: traceID,
                command: spokenInstruction,
                stage: "runtime",
                errorCode: MagicianErrorCode.toolExecutionFailed.rawValue,
                errorMessage: message,
                debugMessage: error.localizedDescription,
                recoverAction: nil,
                focusContext: fallbackFocusContext,
                runtimeEvents: runtimeEvents.snapshot()
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContext.appName,
                    bundleID: fallbackFocusContext.bundleID,
                    inputText: selectionText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    magicianRuntimeVersion: runtimeRoute.runtimeVersion,
                    magicianExecutionTrace: failureTrace,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: appliedSkills
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: nil,
                    model: nil,
                    event: .failed,
                    errorType: MagicianErrorCode.toolExecutionFailed.rawValue,
                    detail: message,
                    audioDuration: audioDurationSeconds
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
        }
    }

    private func recordV4Telemetry(
        traceID: String,
        outcome: V4RunOutcome,
        historyStatus: SessionHistoryStatus,
        audioDurationSeconds: Double
    ) {
        switch historyStatus {
        case .success:
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: nil,
                    model: nil,
                    event: .done,
                    detail: outcome.goalSummary,
                    audioDuration: audioDurationSeconds,
                    transcriptLength: outcome.finalOutputText?.count,
                    stepCount: outcome.stepRecords.count
                )
            )
        case .failed, .cancelled:
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: nil,
                    model: nil,
                    event: .failed,
                    errorType: outcome.failureCode?.rawValue ?? MagicianErrorCode.toolExecutionFailed.rawValue,
                    detail: outcome.finalStatusMessage,
                    audioDuration: audioDurationSeconds
                )
            )
        }
    }

    private func makeV4FailureOutcome(
        request: V4RunRequest,
        error: Error,
        runtimeEvents: [V4RuntimeEvent]
    ) -> V4RunOutcome {
        let message: String
        if let magicianError = error as? MagicianError {
            message = magicianError.userMessage
        } else if let slotError = error as? V4ModelSlotResolutionError {
            message = "模型槽位配置不可用：\(slotError.message)"
        } else {
            message = "魔术先生执行失败：\(error.localizedDescription)"
        }

        return V4RunOutcome(
            sessionID: request.sessionID,
            runID: request.runID,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            status: .failed,
            finalStatusMessage: message,
            finalOutputText: nil,
            displayText: "V4 Runtime Failure",
            stepRecords: runtimeEvents.last?.stepRecords ?? request.stepRecords,
            evidenceSummary: runtimeEvents.last?.evidenceSummary ?? request.evidenceSummary,
            failureCode: v4FailureCode(for: error),
            finishedAt: Date()
        )
    }

    private func v4FailureCode(for error: Error) -> V4FailureCode {
        if error is V4ModelSlotResolutionError {
            return .modelUnavailable
        }

        guard let magicianError = error as? MagicianError else {
            return .toolExecutionFailed
        }

        switch magicianError.code {
        case .permissionDenied:
            return .permissionDenied
        case .intentParseFailed:
            return .invalidRequest
        case .toolExecutionFailed:
            return .toolExecutionFailed
        default:
            return .toolExecutionFailed
        }
    }

    private func handleMagicianRecoverAction(_ recoverAction: String?) {
        guard let recoverAction else {
            return
        }

        switch recoverAction {
        case "open_calendar_permission_settings":
            guard
                let settingsURL = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                )
            else {
                return
            }
            NSWorkspace.shared.open(settingsURL)

        case "open_shortcuts", "create_note_shortcut":
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
            }

        case "configure_mail_account":
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
            }

        case "open_music_app":
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
            }

        case "open_notes_app":
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
            }

        case "open_notes_automation_permission", "open_music_automation_permission":
            if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(settingsURL)
            }

        case "open_feishu_auth":
            guard let backend = currentFeishuCLIAvailability().backend else {
                toastPresenter?.show("未检测到飞书 CLI，请先安装或在设置页填写可执行路径。")
                return
            }
            Task { [weak self] in
                let result = await runProcessWithTimeout(
                    executablePath: backend.executablePath,
                    arguments: ["auth", "login", "--recommend", "--no-wait"],
                    timeoutSeconds: 12,
                    maxOutputCharacters: 6_000,
                    environment: FeishuCLIProvider.buildProcessEnvironment(
                        executablePath: backend.executablePath
                    )
                )
                await MainActor.run {
                    self?.handleFeishuAuthBootstrapResult(result)
                }
            }

        case "open_feishu_cli_docs":
            if let url = URL(string: "https://github.com/larksuite/cli") {
                NSWorkspace.shared.open(url)
            }

        default:
            break
        }
    }

    private func mergedSkills(
        lhs: [SkillRuleID],
        rhs: [SkillRuleID]
    ) -> [SkillRuleID] {
        var merged: [SkillRuleID] = []
        for skill in lhs where !merged.contains(where: { $0 == skill }) {
            merged.append(skill)
        }
        for skill in rhs where !merged.contains(where: { $0 == skill }) {
            merged.append(skill)
        }
        return merged
    }

    private func magicianExecutionTraceText(
        command: String,
        outcome: MagicianAgentRunOutcome,
        runtimeEvents: [MagicianAgentRuntimeEvent]
    ) -> String {
        var lines: [String] = []
        lines.append("goal: \(outcome.goalSummary)")
        lines.append("command: \(command)")
        lines.append("session_id: \(outcome.sessionID)")
        lines.append("run_id: \(outcome.runID)")
        lines.append("")

        appendTraceEvents(&lines, runtimeEvents: runtimeEvents)

        for (index, step) in outcome.steps.enumerated() {
            lines.append("[step \(index + 1)]")
            lines.append("step_id: \(step.id)")
            lines.append("feature: \(step.featureID.rawValue)")
            lines.append("tool: \(step.instruction)")
            appendTraceField(&lines, key: "message", value: step.userMessage)
            appendTraceField(&lines, key: "output", value: step.outputText)
            if let status = step.observation?.verificationStatus.rawValue {
                lines.append("verify: \(status)")
            }
            appendTraceField(&lines, key: "target", value: step.observation?.targetSummary)
            appendTraceField(&lines, key: "evidence", value: step.observation?.evidenceSummary)
            lines.append("")
        }

        lines.append("final_status: \(outcome.finalStatusMessage)")
        appendTraceField(&lines, key: "final_output", value: outcome.finalOutputText)
        appendTraceField(&lines, key: "final_evidence", value: outcome.evidenceSummary)
        return lines.joined(separator: "\n")
    }

    private func magicianFailureExecutionTraceText(
        traceID: String,
        command: String,
        stage: String,
        errorCode: String?,
        errorMessage: String,
        debugMessage: String?,
        recoverAction: String?,
        focusContext: FocusedAppContext,
        runtimeEvents: [MagicianAgentRuntimeEvent]
    ) -> String {
        var lines: [String] = []
        lines.append("goal: (plan unavailable)")
        lines.append("command: \(command)")
        lines.append("trace_id: \(traceID)")
        lines.append("status: failed")
        lines.append("failed_stage: \(stage)")
        lines.append("focus_app: \(focusContext.appName)")
        lines.append("focus_bundle: \(focusContext.bundleID)")
        if let errorCode {
            lines.append("error_code: \(errorCode)")
        }
        appendTraceField(&lines, key: "error_message", value: errorMessage)
        appendTraceField(&lines, key: "error_debug", value: debugMessage)
        appendTraceField(&lines, key: "recover_action", value: recoverAction)
        lines.append("")
        appendTraceEvents(&lines, runtimeEvents: runtimeEvents)
        return lines.joined(separator: "\n")
    }

    private func musicFastExecutionTraceText(
        traceID: String,
        command: String,
        selectionPresent: Bool,
        routerLLMMilliseconds: Int,
        toolMilliseconds: Int?,
        verifyMilliseconds: Int?,
        outcome: MusicFastOutcome?,
        errorCode: String?,
        errorMessage: String?,
        endToEndMilliseconds: Int? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("goal: \(command)")
        lines.append("command: \(command)")
        lines.append("trace_id: \(traceID)")
        lines.append("lane: magicianCommand")
        lines.append("path: music_fast")
        lines.append("selection_present: \(selectionPresent ? "true" : "false")")
        lines.append("router_llm_ms: \(routerLLMMilliseconds)")
        if let toolMilliseconds {
            lines.append("music_tool_ms: \(toolMilliseconds)")
        }
        if let verifyMilliseconds {
            lines.append("music_verify_ms: \(verifyMilliseconds)")
        }
        if let endToEndMilliseconds {
            lines.append("end_to_end_ms: \(endToEndMilliseconds)")
        }
        if let outcome {
            lines.append("status: \(outcome.status == .success ? "completed" : "failed")")
            lines.append("final_status: \(outcome.message)")
            appendTraceField(&lines, key: "final_output", value: outcome.outputText)
            appendTraceField(&lines, key: "final_evidence", value: outcome.evidenceSummary)
        } else {
            lines.append("status: failed")
        }
        if let errorCode {
            lines.append("failure_code: \(errorCode)")
        }
        appendTraceField(&lines, key: "error_message", value: errorMessage)
        return lines.joined(separator: "\n")
    }

    private func appendTraceEvents(
        _ lines: inout [String],
        runtimeEvents: [MagicianAgentRuntimeEvent]
    ) {
        if runtimeEvents.isEmpty {
            lines.append("events: (none)")
            lines.append("")
            return
        }
        lines.append("events:")
        for (index, event) in runtimeEvents.enumerated() {
            lines.append("  [event \(index + 1)] \(event.name.rawValue) | state=\(event.state.rawValue)")
            appendTraceField(&lines, key: "  message", value: event.message)
            if let stepIndex = event.stepIndex, let total = event.totalSteps {
                lines.append("  step: \(stepIndex)/\(total)")
            }
            if let progressHint = event.progressHint {
                lines.append("  progress_hint: \(String(format: "%.3f", progressHint))")
            }
        }
        lines.append("")
    }

    private func appendTraceField(
        _ lines: inout [String],
        key: String,
        value: String?
    ) {
        guard let raw = value else {
            return
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return
        }
        let parts = normalized.components(separatedBy: .newlines)
        if parts.count == 1 {
            lines.append("\(key): \(normalized)")
            return
        }
        lines.append("\(key):")
        for part in parts {
            lines.append("  \(part)")
        }
    }

    private func bindListeningLevel() {
        audioCaptureService.levelPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self else {
                    return
                }
                if self.sessionStore.phase == .listening {
                    self.sessionStore.updateListeningLevel(level)
                }
            }
            .store(in: &cancellables)
    }

    private func bindExternalAppTracking() {
        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.didActivateApplicationNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier != Bundle.main.bundleIdentifier
            else {
                return
            }

            let focusContext = self.contextDetector.focusedAppContext()
            self.lastExternalDictationTarget = DictationWritebackTarget(
                focusContext: focusContext,
                processIdentifier: app.processIdentifier
            )
        }
        .store(in: &cancellables)
    }

    private func discardPendingClipIfNeeded() {
        guard let clip = sessionStore.pendingClip else {
            return
        }
        audioCaptureService.removeClip(at: clip.fileURL)
        sessionStore.clearPendingClipReference()
    }

    private func actionableOutputMessage(
        for error: TextOutputError,
        focusContext: FocusedAppContext
    ) -> String {
        switch error {
        case .emptyText:
            return "转写结果为空，请再说一次。"
        case .accessibilityPermissionMissing:
            return "向 \(focusContext.appName) 直写文本需要辅助功能权限。"
        case .noFocusedElement:
            return "\(focusContext.appName) 当前没有可写入焦点，请先点击输入区域。"
        case .noEditableTarget:
            return "\(focusContext.appName) 当前焦点不可编辑。"
        case let .accessibilityPathFailed(reason):
            return "\(focusContext.appName) AX 直写失败：\(reason)"
        case .pasteboardUnavailable:
            return "粘贴兜底不可用，剪贴板访问失败。"
        case .pasteShortcutInjectionFailed:
            return "粘贴兜底失败，无法发送 Command+V。"
        case let .fallbackFailed(primaryReason):
            return "\(focusContext.appName) 写回失败。AX 路径原因：\(primaryReason)"
        }
    }

    private func actionableRewriteMessage(for error: RewriteProviderError) -> String {
        switch error {
        case .noSelectedText:
            return "没有可改写的选中文本。"
        case .emptyInstruction:
            return "指令为空，可尝试“翻译、润色、精简、结构化整理”等命令。"
        case let .generationFailed(description):
            return "改写请求失败。\(SpeechTranscriptionErrorPresentation.providerFailureHint(from: description))（\(description)）"
        case .invalidGeneratedText:
            return "改写结果为空，请用更清晰的命令再试一次。"
        }
    }

    private func effectiveScenePolicy(for context: FocusedAppContext) -> AppScenePolicy {
        guard skillRuleStore.isEnabled(.appPreferenceBoost) else {
            return AppScenePolicy(
                appName: context.appName,
                bundleID: context.bundleID,
                appPrompt: ""
            )
        }
        return appScenePolicyStore.policy(for: context)
    }

    private func resolveDictationWritebackTarget() -> DictationWritebackTarget? {
        let focusContext = contextDetector.focusedAppContext()
        let currentApp = NSWorkspace.shared.frontmostApplication
        let isCurrentAppSelf = currentApp?.bundleIdentifier == Bundle.main.bundleIdentifier

        if !isCurrentAppSelf {
            let target = DictationWritebackTarget(
                focusContext: focusContext,
                processIdentifier: currentApp?.processIdentifier
            )
            lastExternalDictationTarget = target
            return target
        }

        // 当前就在 PulseType 页面时，如果焦点本身可编辑，也允许直接写回当前窗口。
        if focusContext.hasEditableTarget {
            let target = DictationWritebackTarget(
                focusContext: focusContext,
                processIdentifier: currentApp?.processIdentifier
            )
            return target
        }

        if
            !focusContext.bundleID.isEmpty,
            focusContext.bundleID != Bundle.main.bundleIdentifier
        {
            let target = DictationWritebackTarget(
                focusContext: focusContext,
                processIdentifier: nil
            )
            lastExternalDictationTarget = target
            return target
        }

        return lastExternalDictationTarget
    }

    private func postProcessDictationIfNeeded(
        text: String,
        focusContext: FocusedAppContext,
        appPrompt: String
    ) async -> DictationPostProcessOutcome {
        let userSystemPrompt = skillRuleStore.activeSystemPrompt()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAppPrompt = appPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userSystemPrompt.isEmpty || !normalizedAppPrompt.isEmpty else {
            return DictationPostProcessOutcome(
                route: .asrOnly,
                text: text,
                appliedSkills: [],
                nonBlockingNotice: nil
            )
        }

        guard shouldUseTextProcessing(
            text: text,
            userSystemPrompt: userSystemPrompt,
            appPrompt: normalizedAppPrompt
        ) else {
            return DictationPostProcessOutcome(
                route: .asrOnly,
                text: text,
                appliedSkills: [],
                nonBlockingNotice: nil
            )
        }

        guard providerSettingsStore.isRewriteConfigurationValid else {
            let message = providerSettingsStore.rewriteConfigurationValidationMessage
                ?? "文本模型配置无效。"
            return DictationPostProcessOutcome(
                route: .asrAndTextProcessing,
                text: text,
                appliedSkills: [],
                nonBlockingNotice: "文本处理模型暂未生效（\(message)），已退回本地结果。"
            )
        }

        let loadedKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider()
        let apiKey = loadedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            return DictationPostProcessOutcome(
                route: .asrAndTextProcessing,
                text: text,
                appliedSkills: [],
                nonBlockingNotice: "文本处理模型暂未生效（缺少密钥），已退回本地结果。"
            )
        }

        do {
            let result = try await dictationPostProcessor.process(
                request: DictationPostProcessRequest(
                    transcript: text,
                    focusContext: focusContext,
                    appPrompt: normalizedAppPrompt.isEmpty ? nil : normalizedAppPrompt,
                    userSystemPrompt: userSystemPrompt
                ),
                configuration: providerSettingsStore.rewriteConfiguration,
                apiKey: apiKey
            )
            var applied: [SkillRuleID] = []
            if !userSystemPrompt.isEmpty {
                applied.append(.systemPrompt)
            }
            if !normalizedAppPrompt.isEmpty {
                applied.append(.appPreferenceBoost)
            }
            return DictationPostProcessOutcome(
                route: .asrAndTextProcessing,
                text: result.outputText,
                appliedSkills: applied,
                nonBlockingNotice: nil
            )
        } catch {
            return DictationPostProcessOutcome(
                route: .asrAndTextProcessing,
                text: text,
                appliedSkills: [],
                nonBlockingNotice: "文本处理模型调用失败，已退回本地结果。"
            )
        }
    }

    private func shouldUseTextProcessing(
        text: String,
        userSystemPrompt: String,
        appPrompt: String
    ) -> Bool {
        guard !userSystemPrompt.isEmpty || !appPrompt.isEmpty else {
            return false
        }

        return DictationTextProcessingPolicy.shouldUseModel(text: text)
    }

    private func resolvedLane(context: WakeInvocationContext) -> InputLane {
        switch context.source {
        case .dictationTap:
            return .directDictation
        case .magicianHold:
            return .selectionRewrite
        }
    }

    private func currentFeishuCLIAvailability() -> FeishuCLIAvailability {
        FeishuCLIProvider.detectAvailability(
            executableOverride: providerSettingsStore.resolvedFeishuCLIExecutablePathOverride
        )
    }

    private func handleFeishuAuthBootstrapResult(_ result: MagicianProcessResult) {
        let output = mergedCLIOutput(result)
        if let authURL = firstURL(in: output) {
            NSWorkspace.shared.open(authURL)
            toastPresenter?.show("已打开飞书授权页，完成后再试一次命令。")
            return
        }

        let lowered = output.lowercased()
        if lowered.contains("not configured") || lowered.contains("config init") {
            toastPresenter?.show("飞书 CLI 还没完成配置，请先执行 lark-cli config init --new。")
            return
        }

        if result.exitCode == 0 {
            toastPresenter?.show("已触发飞书授权，请在浏览器完成登录后重试。")
            return
        }

        let brief = output
            .split(separator: "\n")
            .prefix(2)
            .joined(separator: " | ")
        toastPresenter?.show(
            brief.isEmpty
                ? "飞书授权触发失败，请先在终端执行 lark-cli auth login --recommend。"
                : "飞书授权失败：\(brief)"
        )
    }

    private func mergedCLIOutput(_ result: MagicianProcessResult) -> String {
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        return result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func firstURL(in text: String) -> URL? {
        let pattern = #"https?://[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        let raw = nsText.substring(with: match.range)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}"))
        return URL(string: raw)
    }

    private func historyMode(for lane: InputLane) -> SessionHistoryMode {
        switch lane {
        case .directDictation:
            return .dictation
        case .selectionRewrite:
            return .selectionRewrite
        case .brainstormDiscussion:
            return .brainstorm
        }
    }
}

private final class LockedV4RuntimeEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [V4RuntimeEvent] = []

    func append(_ event: V4RuntimeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [V4RuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private final class LockedMagicianRuntimeEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MagicianAgentRuntimeEvent] = []

    func append(_ event: MagicianAgentRuntimeEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [MagicianAgentRuntimeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
