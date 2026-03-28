import AppKit
import Combine
import EventKit
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
    private let magicianStatusResolver: MagicianStatusResolver
    private let workflowTelemetryReporter: any WorkflowTelemetryReporting
    private let magicianIntentRouter: any MagicianIntentRouting
    private let magicianWorkflowPlanner: any MagicianWorkflowPlanning
    private let magicianWorkflowExecutor: MagicianWorkflowExecutor
    private let magicianToolExecutor: any MagicianToolExecuting
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
    private var pendingMagicianSelectionSnapshot: FocusedSelectionSnapshot?
    private var pendingMagicianSelectionCaptureTask: Task<FocusedSelectionSnapshot?, Never>?

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
        magicianStatusResolver: MagicianStatusResolver = MagicianStatusResolver(),
        workflowTelemetryReporter: (any WorkflowTelemetryReporting)? = nil,
        magicianIntentRouter: (any MagicianIntentRouting)? = nil,
        magicianWorkflowPlanner: (any MagicianWorkflowPlanning)? = nil,
        magicianWorkflowExecutor: MagicianWorkflowExecutor? = nil,
        magicianToolExecutor: (any MagicianToolExecuting)? = nil,
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
        self.magicianStatusResolver = magicianStatusResolver
        self.workflowTelemetryReporter = workflowTelemetryReporter ?? WorkflowTelemetryReporter(
            speechPipelineLogger: speechPipelineLogger
        )
        let resolvedMailAddressBookStore = mailAddressBookStore ?? MailAddressBookStore()
        let resolvedIntentRouter = magicianIntentRouter ?? LLMMagicianIntentRouter(
            providerSettingsStore: providerSettingsStore
        )
        self.magicianIntentRouter = resolvedIntentRouter
        if let magicianWorkflowPlanner {
            self.magicianWorkflowPlanner = magicianWorkflowPlanner
        } else if magicianIntentRouter != nil {
            self.magicianWorkflowPlanner = MagicianSingleIntentWorkflowPlannerAdapter(
                intentRouter: resolvedIntentRouter
            )
        } else {
            self.magicianWorkflowPlanner = LLMMagicianWorkflowPlanner(
                providerSettingsStore: providerSettingsStore,
                intentRouter: resolvedIntentRouter
            )
        }
        self.magicianWorkflowExecutor = magicianWorkflowExecutor ?? MagicianWorkflowExecutor()
        self.magicianToolExecutor = magicianToolExecutor ?? MagicianToolExecutor(
            providerSettingsStore: providerSettingsStore,
            mailAddressBookStore: resolvedMailAddressBookStore
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
        clearPendingMagicianSelectionState()

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
        clearPendingMagicianSelectionState()
        currentDictationTarget = nil
        discardPendingClipIfNeeded()
        sessionStore.completeInsertion()
        currentTraceID = nil
    }

    func handleResetInput() {
        cancelBrainstormDurationGuard()
        clearPendingMagicianSelectionState()
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
            if lane == .selectionRewrite {
                prepareMagicianSelectionCapture()
            } else {
                clearPendingMagicianSelectionState()
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
            clearPendingMagicianSelectionState()
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

    private func prepareMagicianSelectionCapture() {
        pendingMagicianSelectionSnapshot = textOutputCoordinator.currentSelectionSnapshot()
        pendingMagicianSelectionCaptureTask?.cancel()
        pendingMagicianSelectionCaptureTask = Task { [textOutputCoordinator] in
            await textOutputCoordinator.captureSelectionSnapshot()
        }
    }

    private func clearPendingMagicianSelectionState() {
        pendingMagicianSelectionCaptureTask?.cancel()
        pendingMagicianSelectionCaptureTask = nil
        pendingMagicianSelectionSnapshot = nil
    }

    private func resolvedMagicianSelectionSnapshot() async -> FocusedSelectionSnapshot? {
        if
            let pendingMagicianSelectionSnapshot,
            !pendingMagicianSelectionSnapshot.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return pendingMagicianSelectionSnapshot
        }

        if let capturedSnapshot = await pendingMagicianSelectionCaptureTask?.value {
            pendingMagicianSelectionSnapshot = capturedSnapshot
            pendingMagicianSelectionCaptureTask = nil
            return capturedSnapshot
        }

        let fallbackSnapshot = textOutputCoordinator.currentSelectionSnapshot()
        pendingMagicianSelectionSnapshot = fallbackSnapshot
        pendingMagicianSelectionCaptureTask = nil
        return fallbackSnapshot
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
        defer {
            clearPendingMagicianSelectionState()
        }
        let traceID = ensureTraceID()
        let rawInstruction = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionApplyResult = MagicianCommandSanitizer.sanitize(rawInstruction)
        let processedInstruction = instructionApplyResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenInstruction = processedInstruction.isEmpty ? rawInstruction : processedInstruction
        let initialFocusContext = contextDetector.focusedAppContext()
        let selectionSnapshot = await resolvedMagicianSelectionSnapshot()
        if abortIfSessionCancelled() {
            return
        }
        let fallbackFocusContext = selectionSnapshot?.focusContext ?? initialFocusContext
        let selectionText = selectionSnapshot?.selectedText ?? ""
        let workflowStartedAt = Date()

        guard !spokenInstruction.isEmpty else {
            let message = "改写指令为空，请重试并说出明确命令。"
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
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: transcription.providerName,
                model: transcription.modelName,
                httpStatus: nil,
                stage: "magician.intent.failed",
                errorType: "emptyCommand",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let hasSelectionText = !selectionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabledFeatures: Set<MagicianFeatureID> = {
            if hasSelectionText {
                return magicianFeatureToggleStore
                    .enabledFeatures
                    .subtracting([.feishuCLI])
            }
            return magicianFeatureToggleStore.isEnabled(.feishuCLI)
                ? [.feishuCLI]
                : []
        }()
        let plannerModelConfiguration = magicianPlannerModelConfiguration(
            enabledFeatures: enabledFeatures,
            selectionText: selectionText
        )
        guard !enabledFeatures.isEmpty else {
            let message = hasSelectionText
                ? "当前没有可用的选中流程能力，请先在魔术先生页面开启。"
                : "无选中场景需要先开启飞书 CLI 能力。"
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
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: transcription.providerName,
                model: transcription.modelName,
                httpStatus: nil,
                stage: "magician.intent.failed",
                errorType: "featureDisabled",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let workflowPlan: MagicianWorkflowPlan
        let workflowPlanStartedAt = Date()
        do {
            workflowPlan = try await magicianWorkflowPlanner.plan(
                command: spokenInstruction,
                selection: selectionSnapshot?.selectedText,
                enabledFeatures: enabledFeatures
            )
            if abortIfSessionCancelled() {
                return
            }
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: plannerModelConfiguration.providerName,
                    model: plannerModelConfiguration.modelName,
                    event: .planSuccess,
                    detail: "steps=\(workflowPlan.steps.map(\.feature.rawValue).joined(separator: "->")),confidence=\(String(format: "%.2f", workflowPlan.confidence))",
                    audioDuration: audioDurationSeconds,
                    transcriptLength: spokenInstruction.count,
                    workflowVersion: workflowPlan.version,
                    stepCount: workflowPlan.steps.count,
                    confidence: workflowPlan.confidence,
                    durationMs: Self.elapsedMilliseconds(since: workflowPlanStartedAt)
                )
            )
        } catch let magicianError as MagicianError {
            if abortIfSessionCancelled() {
                return
            }
            let message = magicianError.userMessage
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
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: plannerModelConfiguration.providerName,
                    model: plannerModelConfiguration.modelName,
                    event: .planFailed,
                    errorType: magicianError.code.rawValue,
                    detail: magicianError.debugMessage ?? message,
                    audioDuration: audioDurationSeconds,
                    durationMs: Self.elapsedMilliseconds(since: workflowPlanStartedAt)
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        } catch {
            if abortIfSessionCancelled() {
                return
            }
            let message = "流程解析失败，请换个说法再试。"
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
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: plannerModelConfiguration.providerName,
                    model: plannerModelConfiguration.modelName,
                    event: .planFailed,
                    errorType: "workflow_parse_failed",
                    detail: error.localizedDescription,
                    audioDuration: audioDurationSeconds,
                    durationMs: Self.elapsedMilliseconds(since: workflowPlanStartedAt)
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        if abortIfSessionCancelled() {
            return
        }
        sessionStore.markRewriting(
            actionLabel: "流程预览：\(workflowPreviewLabel(workflowPlan))",
            stage: .toolAction,
            progressHint: SessionHUDProgressHint.workflowPreview
        )
        if let previewDelay = Self.workflowPreviewDelayNanoseconds(stepCount: workflowPlan.steps.count) {
            try? await Task.sleep(nanoseconds: previewDelay)
        }
        if abortIfSessionCancelled() {
            return
        }

        let workflowContext = MagicianWorkflowExecutionContext(
            command: spokenInstruction,
            selection: selectionSnapshot,
            focusContext: fallbackFocusContext,
            traceID: traceID
        )

        let workflowExecutionStartedAt = Date()
        do {
            let executionResult = try await magicianWorkflowExecutor.execute(
                plan: workflowPlan,
                context: workflowContext
            ) { [weak self] request in
                guard let self else {
                    throw MagicianError(
                        code: .toolExecutionFailed,
                        userMessage: "流程执行被中断，请重试。",
                        debugMessage: "interaction coordinator released during workflow",
                        recoverAction: "retry_command"
                    )
                }
                return try await self.executeWorkflowStep(
                    request,
                    isFinalStep: request.index == workflowPlan.steps.count - 1,
                    transcription: transcription,
                    spokenInstruction: spokenInstruction,
                    instructionApplyResult: instructionApplyResult,
                    audioDurationSeconds: audioDurationSeconds
                )
            }
            if abortIfSessionCancelled() {
                return
            }
            let summaryDisplay = workflowExecutionDisplayText(executionResult)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: fallbackFocusContext.appName,
                    bundleID: fallbackFocusContext.bundleID,
                    inputText: selectionText,
                    outputText: executionResult.finalOutputText,
                    instructionText: spokenInstruction,
                    displayText: summaryDisplay,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            sessionStore.completeAction(statusMessage: executionResult.finalStatusMessage)
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: plannerModelConfiguration.providerName,
                    model: plannerModelConfiguration.modelName,
                    event: .done,
                    detail: "steps=\(executionResult.stepResults.count),final=\(executionResult.finalStatusMessage)",
                    audioDuration: audioDurationSeconds,
                    transcriptLength: executionResult.finalOutputText?.count,
                    workflowVersion: workflowPlan.version,
                    stepCount: executionResult.stepResults.count,
                    durationMs: Self.elapsedMilliseconds(since: workflowStartedAt)
                )
            )
            currentTraceID = nil
        } catch let magicianError as MagicianError {
            if abortIfSessionCancelled() {
                return
            }
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
                    status: .failed,
                    errorMessage: magicianError.userMessage,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            handleMagicianRecoverAction(magicianError.recoverAction)
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: plannerModelConfiguration.providerName,
                    model: plannerModelConfiguration.modelName,
                    event: .failed,
                    errorType: magicianError.code.rawValue,
                    detail: magicianError.debugMessage ?? magicianError.userMessage,
                    audioDuration: audioDurationSeconds,
                    workflowVersion: workflowPlan.version,
                    stepCount: workflowPlan.steps.count,
                    durationMs: Self.elapsedMilliseconds(since: workflowExecutionStartedAt)
                )
            )
            sessionStore.fail(message: magicianError.userMessage)
            currentTraceID = nil
        } catch {
            if abortIfSessionCancelled() {
                return
            }
            let message = "流程执行失败：\(error.localizedDescription)"
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
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: plannerModelConfiguration.providerName,
                    model: plannerModelConfiguration.modelName,
                    event: .failed,
                    errorType: MagicianErrorCode.toolExecutionFailed.rawValue,
                    detail: message,
                    audioDuration: audioDurationSeconds,
                    workflowVersion: workflowPlan.version,
                    stepCount: workflowPlan.steps.count,
                    durationMs: Self.elapsedMilliseconds(since: workflowExecutionStartedAt)
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
        }
    }

    private func workflowPreviewLabel(_ plan: MagicianWorkflowPlan) -> String {
        let labels = plan.steps.map { $0.feature.displayName }
        if labels.isEmpty {
            return "空流程"
        }
        return labels.joined(separator: " -> ")
    }

    private func workflowExecutionDisplayText(_ result: MagicianWorkflowExecutionResult) -> String {
        let labels = result.stepResults.map { $0.step.feature.displayName }
        if labels.isEmpty {
            return "流程已完成"
        }
        let summary = labels.joined(separator: " -> ")
        return "流程：\(summary)"
    }

    static func workflowPreviewDelayNanoseconds(stepCount: Int) -> UInt64? {
        stepCount > 1 ? 250_000_000 : nil
    }

    static func workflowStepProgressLabel(
        index: Int,
        totalSteps: Int,
        feature: MagicianFeatureID
    ) -> String {
        let safeTotal = max(1, totalSteps)
        let safeIndex = min(max(1, index), safeTotal)
        return "第\(safeIndex)/\(safeTotal)步：\(feature.progressTitle)"
    }

    static func workflowStepProgressHint(index: Int, totalSteps: Int) -> Double {
        SessionHUDProgressHint.workflowStep(index: index, totalSteps: totalSteps)
    }

    private func workflowStepInputText(from request: MagicianWorkflowStepExecutionRequest) -> String {
        switch request.step.inputBinding {
        case .selectionText:
            return request.context.selectedText
        case .previousOutput:
            return request.latestOutputText ?? request.context.selectedText
        case .commandOnly:
            return ""
        }
    }

    private func resolvedWorkflowToolParams(
        for request: MagicianWorkflowStepExecutionRequest,
        sourceText: String,
        command: String
    ) -> MagicianIntentParams {
        var params = request.step.params
        let normalizedSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.step.inputBinding == .previousOutput, !normalizedSource.isEmpty else {
            return params
        }

        switch request.step.feature {
        case .createNote:
            params.noteBody = normalizedSource
        case .composeEmailDraft:
            params.mailBody = normalizedSource
            if params.mailDeliveryMode == nil {
                params.mailDeliveryMode = .autoSendIfResolved
            }
        case .createEvent:
            let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            if
                let title = params.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                !title.isEmpty,
                isLikelyInstructionPhrase(
                    title,
                    command: normalizedCommand,
                    actionTokens: ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event"]
                )
            {
                params.title = nil
            }
            if params.notes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                params.notes = normalizedSource
            }
        case .textTransform:
            break
        case .feishuCLI:
            break
        }

        return params
    }

    private func isAutoSendMailResult(_ result: MagicianExecutionResult) -> Bool {
        result.userMessage.contains("邮件已发出")
    }

    private func isDraftOnlyMailResult(_ result: MagicianExecutionResult) -> Bool {
        if let historyText = result.historyDisplayText, historyText.contains("邮件待确认") {
            return true
        }
        let message = result.userMessage
        return message.contains("草稿") || message.contains("待你确认")
    }

    private static func elapsedMilliseconds(since startDate: Date) -> Int {
        let elapsed = Date().timeIntervalSince(startDate)
        return max(0, Int((elapsed * 1000).rounded()))
    }

    private func executeWorkflowStep(
        _ request: MagicianWorkflowStepExecutionRequest,
        isFinalStep: Bool,
        transcription: SpeechTranscriptionResult,
        spokenInstruction: String,
        instructionApplyResult _: SkillApplyResult,
        audioDurationSeconds: TimeInterval
    ) async throws -> MagicianWorkflowStepExecutionResponse {
        if abortIfSessionCancelled() {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "流程已取消。",
                debugMessage: "workflow cancelled",
                recoverAction: nil
            )
        }

        permissionsCenter.refreshStatuses()
        let dependencies = currentMagicianDependenciesSnapshot()
        let requirement = magicianStatusResolver.requirement(
            for: request.step.feature,
            dependencies: dependencies
        )
        let shouldBypassRequirement = request.step.feature == .createEvent
            && dependencies.eventAuthorizationStatus == .notDetermined
        if case let .blocked(reason, prompt) = requirement, !shouldBypassRequirement {
            handleMagicianPermissionAction(prompt.primaryAction)
            throw MagicianError(
                code: .permissionDenied,
                userMessage: "\(request.step.feature.displayName)：\(reason)",
                debugMessage: "workflow requirement blocked for \(request.step.feature.rawValue)",
                recoverAction: nil
            )
        }

        let stepCommand = request.step.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCommand = (stepCommand?.isEmpty == false) ? stepCommand! : spokenInstruction
        let stepInputText = workflowStepInputText(from: request)
        let stepStartedAt = Date()
        let stepModelConfiguration = magicianStepModelConfiguration(feature: request.step.feature)
        sessionStore.markRewriting(
            actionLabel: Self.workflowStepProgressLabel(
                index: request.index + 1,
                totalSteps: request.totalSteps,
                feature: request.step.feature
            ),
            stage: .toolAction,
            progressHint: Self.workflowStepProgressHint(
                index: request.index + 1,
                totalSteps: request.totalSteps
            )
        )

        if request.step.feature == .textTransform {
            return try await executeWorkflowTextTransformStep(
                request: request,
                stepCommand: resolvedCommand,
                stepInputText: stepInputText,
                isFinalStep: isFinalStep,
                transcription: transcription,
                audioDurationSeconds: audioDurationSeconds,
                stepStartedAt: stepStartedAt
            )
        }

        let sourceText: String = if request.step.feature == .feishuCLI {
            ""
        } else if stepInputText.isEmpty {
            request.latestOutputText ?? request.context.selectedText
        } else {
            stepInputText
        }
        var params = resolvedWorkflowToolParams(
            for: request,
            sourceText: sourceText,
            command: resolvedCommand
        )
        if request.step.feature == .composeEmailDraft, params.mailDeliveryMode == nil {
            params.mailDeliveryMode = .autoSendIfResolved
        }
        let intent = MagicianIntent(
            intent: request.step.feature,
            confidence: 0.86,
            sourceText: sourceText,
            params: params
        )
        let stepSelectionSnapshot: FocusedSelectionSnapshot? = {
            if request.step.feature == .feishuCLI {
                return nil
            }
            if sourceText.isEmpty {
                return request.context.selection
            }
            return FocusedSelectionSnapshot(
                focusContext: request.context.focusContext,
                selectedText: sourceText
            )
        }()
        let executionContext = MagicianExecutionContext(
            command: resolvedCommand,
            selection: stepSelectionSnapshot,
            focusContext: request.context.focusContext
        )

        do {
            let result = try await magicianToolExecutor.execute(
                intent: intent,
                context: executionContext
            )
            let autoSendConfigured: Bool? = if request.step.feature == .composeEmailDraft {
                params.mailDeliveryMode == .autoSendIfResolved
            } else {
                nil
            }
            let autoSendHit: Bool? = if autoSendConfigured == true {
                isAutoSendMailResult(result)
            } else {
                nil
            }
            let draftOnlyFallback: Bool? = if request.step.feature == .composeEmailDraft {
                isDraftOnlyMailResult(result)
            } else {
                nil
            }
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: request.context.traceID,
                    lane: .selectionRewrite,
                    provider: stepModelConfiguration.providerName,
                    model: stepModelConfiguration.modelName,
                    event: .stepSuccess,
                    detail: "index=\(request.index + 1),feature=\(request.step.feature.rawValue)",
                    audioDuration: audioDurationSeconds,
                    transcriptLength: result.outputText?.count,
                    stepCount: request.totalSteps,
                    stepIndex: request.index + 1,
                    stepID: request.step.stepID,
                    feature: request.step.feature.rawValue,
                    durationMs: Self.elapsedMilliseconds(since: stepStartedAt),
                    attempt: request.attempt,
                    autoSendConfigured: autoSendConfigured,
                    autoSendHit: autoSendHit,
                    draftOnlyFallback: draftOnlyFallback
                )
            )
            return MagicianWorkflowStepExecutionResponse(
                userMessage: result.userMessage,
                outputText: result.outputText,
                historyDisplayText: result.historyDisplayText,
                fallbackUsed: result.fallbackUsed
            )
        } catch let magicianError as MagicianError {
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: request.context.traceID,
                    lane: .selectionRewrite,
                    provider: stepModelConfiguration.providerName,
                    model: stepModelConfiguration.modelName,
                    event: .stepFailed,
                    errorType: magicianError.code.rawValue,
                    detail: magicianError.debugMessage ?? magicianError.userMessage,
                    audioDuration: audioDurationSeconds,
                    stepCount: request.totalSteps,
                    stepIndex: request.index + 1,
                    stepID: request.step.stepID,
                    feature: request.step.feature.rawValue,
                    durationMs: Self.elapsedMilliseconds(since: stepStartedAt),
                    attempt: request.attempt
                )
            )
            throw magicianError
        } catch {
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: request.context.traceID,
                    lane: .selectionRewrite,
                    provider: stepModelConfiguration.providerName,
                    model: stepModelConfiguration.modelName,
                    event: .stepFailed,
                    errorType: MagicianErrorCode.toolExecutionFailed.rawValue,
                    detail: error.localizedDescription,
                    audioDuration: audioDurationSeconds,
                    stepCount: request.totalSteps,
                    stepIndex: request.index + 1,
                    stepID: request.step.stepID,
                    feature: request.step.feature.rawValue,
                    durationMs: Self.elapsedMilliseconds(since: stepStartedAt),
                    attempt: request.attempt
                )
            )
            throw error
        }
    }

    private func executeWorkflowTextTransformStep(
        request: MagicianWorkflowStepExecutionRequest,
        stepCommand: String,
        stepInputText: String,
        isFinalStep: Bool,
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval,
        stepStartedAt: Date
    ) async throws -> MagicianWorkflowStepExecutionResponse {
        let normalizedInput = stepInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            throw MagicianError(
                code: .selectionEmpty,
                userMessage: "文字处理步骤需要先选中一段文本。",
                debugMessage: "workflow text transform input empty",
                recoverAction: "select_text_first"
            )
        }

        guard providerSettingsStore.isRewriteConfigurationValid else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: providerSettingsStore.rewriteConfigurationValidationMessage ?? "改写模型配置无效。",
                debugMessage: providerSettingsStore.rewriteConfigurationValidationMessage,
                recoverAction: "open_provider_settings"
            )
        }

        let loadedKey = try providerSettingsStore.loadAPIKeyForRewriteProvider()
        let apiKey = loadedKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "缺少服务商 API 密钥，请到设置页填写。",
                debugMessage: "workflow text transform api key missing",
                recoverAction: "open_provider_settings"
            )
        }

        let rewriteConfiguration = providerSettingsStore.rewriteConfiguration
        guard let rewriteProvider = rewriteProviderRegistry.provider(for: rewriteConfiguration.providerType) else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "当前构建不含所选改写 provider。",
                debugMessage: "rewrite provider unavailable for workflow",
                recoverAction: "open_provider_settings"
            )
        }

        let rewriteResult: SelectionRewriteResult
        do {
            rewriteResult = try await rewriteProvider.rewrite(
                request: SelectionRewriteRequest(
                    selectedText: normalizedInput,
                    spokenInstruction: stepCommand,
                    focusContext: request.context.focusContext,
                    outputBias: .neutral,
                    appPrompt: nil,
                    userSystemPrompt: nil
                ),
                configuration: rewriteConfiguration,
                apiKey: apiKey
            )
        } catch let rewriteError as RewriteProviderError {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: actionableRewriteMessage(for: rewriteError),
                debugMessage: rewriteError.localizedDescription,
                recoverAction: "retry_command"
            )
        }

        let outputApplyResult = skillRuleStore.applyRewriteOutput(
            rewriteResult.rewrittenText,
            outputBias: .neutral
        )
        let finalRewriteText: String = {
            let normalized = outputApplyResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? rewriteResult.rewrittenText : normalized
        }()

        if !isFinalStep {
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: request.context.traceID,
                    lane: .selectionRewrite,
                    provider: rewriteResult.providerName,
                    model: rewriteResult.modelName,
                    event: .stepSuccess,
                    detail: "index=\(request.index + 1),feature=text_transform,path=memory_only",
                    audioDuration: audioDurationSeconds,
                    transcriptLength: finalRewriteText.count,
                    stepCount: request.totalSteps,
                    stepIndex: request.index + 1,
                    stepID: request.step.stepID,
                    feature: request.step.feature.rawValue,
                    durationMs: Self.elapsedMilliseconds(since: stepStartedAt),
                    attempt: request.attempt
                )
            )
            return MagicianWorkflowStepExecutionResponse(
                userMessage: "文字处理已完成",
                outputText: finalRewriteText,
                historyDisplayText: "文字处理：\(summarizedHistoryText(finalRewriteText))",
                fallbackUsed: false
            )
        }

        do {
            sessionStore.markInserting(
                transcription: transcription,
                focusContext: request.context.focusContext
            )
            let outputResult = try await textOutputCoordinator.write(
                request: TextOutputRequest(
                    text: finalRewriteText,
                    operation: .replaceSelectedText,
                    focusContext: request.context.focusContext
                )
            )
            workflowTelemetryReporter.record(
                WorkflowTelemetryEvent(
                    traceID: request.context.traceID,
                    lane: .selectionRewrite,
                    provider: rewriteResult.providerName,
                    model: rewriteResult.modelName,
                    event: .stepSuccess,
                    detail: "index=\(request.index + 1),feature=text_transform,path=\(outputResult.path.rawValue)",
                    audioDuration: audioDurationSeconds,
                    transcriptLength: finalRewriteText.count,
                    stepCount: request.totalSteps,
                    stepIndex: request.index + 1,
                    stepID: request.step.stepID,
                    feature: request.step.feature.rawValue,
                    durationMs: Self.elapsedMilliseconds(since: stepStartedAt),
                    attempt: request.attempt
                )
            )
            return MagicianWorkflowStepExecutionResponse(
                userMessage: "文字处理并写入完成",
                outputText: finalRewriteText,
                historyDisplayText: "文字处理：\(summarizedHistoryText(finalRewriteText))",
                fallbackUsed: outputResult.usedFallback
            )
        } catch let outputError as TextOutputError {
            if
                shouldFallbackToClipboardForMagician(outputError),
                persistTextToClipboard(finalRewriteText)
            {
                workflowTelemetryReporter.record(
                    WorkflowTelemetryEvent(
                        traceID: request.context.traceID,
                        lane: .selectionRewrite,
                        provider: rewriteResult.providerName,
                        model: rewriteResult.modelName,
                        event: .stepSuccess,
                        detail: "index=\(request.index + 1),feature=text_transform,path=\(TextOutputPath.clipboardOnly.rawValue)",
                        audioDuration: audioDurationSeconds,
                        transcriptLength: finalRewriteText.count,
                        stepCount: request.totalSteps,
                        stepIndex: request.index + 1,
                        stepID: request.step.stepID,
                        feature: request.step.feature.rawValue,
                        durationMs: Self.elapsedMilliseconds(since: stepStartedAt),
                        attempt: request.attempt
                    )
                )
                return MagicianWorkflowStepExecutionResponse(
                    userMessage: "未检测到可写入输入框，结果已复制到剪贴板。",
                    outputText: finalRewriteText,
                    historyDisplayText: "文字处理：\(summarizedHistoryText(finalRewriteText))",
                    fallbackUsed: true
                )
            }
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: actionableOutputMessage(
                    for: outputError,
                    focusContext: request.context.focusContext
                ),
                debugMessage: outputError.localizedDescription,
                recoverAction: "retry_command"
            )
        }
    }

    private func executeTextTransformIntent(
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval,
        spokenInstruction: String,
        snapshot: FocusedSelectionSnapshot,
        instructionApplyResult: SkillApplyResult,
        traceID: String
    ) async {
        if abortIfSessionCancelled() {
            return
        }
        let quickActionLabel = MagicianTextTransformLabelResolver.label(for: spokenInstruction)

        guard providerSettingsStore.isRewriteConfigurationValid else {
            let message = providerSettingsStore.rewriteConfigurationValidationMessage
                ?? "改写模型配置无效。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        guard let loadedKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider() else {
            let message = "缺少服务商 API 密钥，请到设置页填写。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let normalizedKey = loadedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            let message = "缺少服务商 API 密钥，请到设置页填写。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let rewriteConfiguration = providerSettingsStore.rewriteConfiguration
        guard let rewriteProvider = rewriteProviderRegistry.provider(for: rewriteConfiguration.providerType) else {
            let message = "当前构建不含所选改写 provider。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        sessionStore.markRewriting(
            actionLabel: quickActionLabel,
            stage: .textTransform,
            progressHint: SessionHUDProgressHint.textTransform
        )
        var clipboardCandidateText: String?
        do {
            let rewriteResult = try await rewriteProvider.rewrite(
                request: SelectionRewriteRequest(
                    selectedText: snapshot.selectedText,
                    spokenInstruction: spokenInstruction,
                    focusContext: snapshot.focusContext,
                    outputBias: .neutral,
                    appPrompt: nil,
                    userSystemPrompt: nil
                ),
                configuration: rewriteConfiguration,
                apiKey: normalizedKey
            )
            if abortIfSessionCancelled() {
                return
            }
            let outputApplyResult = skillRuleStore.applyRewriteOutput(
                rewriteResult.rewrittenText,
                outputBias: .neutral
            )
            let combinedSkills = mergedSkills(
                lhs: instructionApplyResult.appliedSkills,
                rhs: outputApplyResult.appliedSkills
            )
            let finalRewriteText: String = {
                let normalized = outputApplyResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? rewriteResult.rewrittenText : normalized
            }()
            clipboardCandidateText = finalRewriteText

            let outputRequest = TextOutputRequest(
                text: finalRewriteText,
                operation: .replaceSelectedText,
                focusContext: snapshot.focusContext
            )

            sessionStore.markInserting(
                transcription: transcription,
                focusContext: snapshot.focusContext
            )

            let outputResult = try await textOutputCoordinator.write(request: outputRequest)
            sessionStore.completeInsertion(
                outputResult: outputResult,
                note: "如需回退，可在目标应用按 Command+Z。"
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: finalRewriteText,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteResult.providerName,
                    rewriteModel: rewriteResult.modelName,
                    outputPath: outputResult.path,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: combinedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: rewriteResult.providerName,
                model: rewriteResult.modelName,
                httpStatus: nil,
                stage: "magician.tool.success",
                detail: "intent=text_transform,path=\(outputResult.path.rawValue)",
                audioDuration: audioDurationSeconds,
                transcriptLength: finalRewriteText.count
            )
            currentTraceID = nil
        } catch let rewriteError as RewriteProviderError {
            if abortIfSessionCancelled() {
                return
            }
            let message = actionableRewriteMessage(for: rewriteError)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteConfiguration.providerName,
                    rewriteModel: rewriteConfiguration.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: rewriteConfiguration.providerName,
                model: rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.tool.failed",
                errorType: "text_transform_failed",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
        } catch let outputError as TextOutputError {
            if abortIfSessionCancelled() {
                return
            }
            if
                shouldFallbackToClipboardForMagician(outputError),
                let clipboardCandidateText,
                persistTextToClipboard(clipboardCandidateText)
            {
                let message = "未检测到可写入输入框，结果已复制到剪贴板。"
                localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: clipboardCandidateText,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteConfiguration.providerName,
                        rewriteModel: rewriteConfiguration.modelName,
                        outputPath: .clipboardOnly,
                        status: .success,
                        audioDurationSeconds: audioDurationSeconds,
                        appliedSkills: instructionApplyResult.appliedSkills
                    )
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: .selectionRewrite,
                    provider: rewriteConfiguration.providerName,
                    model: rewriteConfiguration.modelName,
                    httpStatus: nil,
                    stage: "magician.tool.success",
                    detail: "intent=text_transform,path=\(TextOutputPath.clipboardOnly.rawValue)",
                    audioDuration: audioDurationSeconds,
                    transcriptLength: clipboardCandidateText.count
                )
                sessionStore.completeAction(statusMessage: message)
                currentTraceID = nil
                return
            }

            let message = actionableOutputMessage(for: outputError, focusContext: snapshot.focusContext)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteConfiguration.providerName,
                    rewriteModel: rewriteConfiguration.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: rewriteConfiguration.providerName,
                model: rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.tool.failed",
                errorType: "text_output_failed",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
        } catch {
            if abortIfSessionCancelled() {
                return
            }
            let message = "改写失败：\(error.localizedDescription)"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: .textTransform,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteConfiguration.providerName,
                    rewriteModel: rewriteConfiguration.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: rewriteConfiguration.providerName,
                model: rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.tool.failed",
                errorType: "text_transform_failed",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
        }
    }

    private func shouldFallbackToClipboardForMagician(_ error: TextOutputError) -> Bool {
        switch error {
        case .emptyText, .pasteboardUnavailable:
            return false
        case .accessibilityPermissionMissing,
             .noFocusedElement,
             .noEditableTarget,
             .accessibilityPathFailed,
             .pasteShortcutInjectionFailed,
             .fallbackFailed:
            return true
        }
    }

    private func persistTextToClipboard(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(trimmed, forType: .string)
    }

    private func executeMagicianToolIntent(
        _ intent: MagicianIntent,
        transcription: SpeechTranscriptionResult,
        spokenInstruction: String,
        executionContext: MagicianExecutionContext,
        historyInputText: String,
        instructionApplyResult: SkillApplyResult,
        audioDurationSeconds: TimeInterval,
        traceID: String
    ) async {
        if abortIfSessionCancelled() {
            return
        }
        sessionStore.markRewriting(
            actionLabel: intent.intent.progressTitle,
            stage: .toolAction,
            progressHint: Self.workflowStepProgressHint(index: 1, totalSteps: 1)
        )
        do {
            let result = try await magicianToolExecutor.execute(
                intent: intent,
                context: executionContext
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: executionContext.focusContext.appName,
                    bundleID: executionContext.focusContext.bundleID,
                    inputText: historyInputText,
                    outputText: result.outputText,
                    instructionText: spokenInstruction,
                    magicianFeatureID: intent.intent,
                    displayText: result.historyDisplayText,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            sessionStore.completeAction(statusMessage: result.userMessage)
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.tool.success",
                detail: "intent=\(intent.intent.rawValue),fallback=\(result.fallbackUsed)",
                audioDuration: audioDurationSeconds,
                transcriptLength: result.outputText?.count
            )
            currentTraceID = nil
        } catch let magicianError as MagicianError {
            if abortIfSessionCancelled() {
                return
            }
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: executionContext.focusContext.appName,
                    bundleID: executionContext.focusContext.bundleID,
                    inputText: historyInputText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: intent.intent,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: magicianError.userMessage,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            handleMagicianRecoverAction(magicianError.recoverAction)
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.tool.failed",
                errorType: magicianError.code.rawValue,
                detail: magicianError.debugMessage ?? magicianError.userMessage,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: magicianError.userMessage)
            currentTraceID = nil
        } catch {
            if abortIfSessionCancelled() {
                return
            }
            let message = "执行失败：\(error.localizedDescription)"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: executionContext.focusContext.appName,
                    bundleID: executionContext.focusContext.bundleID,
                    inputText: historyInputText,
                    outputText: nil,
                    instructionText: spokenInstruction,
                    magicianFeatureID: intent.intent,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: instructionApplyResult.appliedSkills
                )
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.tool.failed",
                errorType: MagicianErrorCode.toolExecutionFailed.rawValue,
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
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

        case "open_feishu_auth":
            if let feishuPath = FeishuCLIProvider.detectAvailability().backend?.executablePath {
                Task {
                    _ = await runProcessWithTimeout(
                        executablePath: feishuPath,
                        arguments: ["auth", "status"],
                        timeoutSeconds: 8,
                        maxOutputCharacters: 6_000
                    )
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

    private func handleMagicianPermissionAction(_ action: MagicianPermissionAction) {
        switch action {
        case .requestAccessibility:
            permissionsCenter.requestAccess(for: .accessibility)

        case .requestCalendarAccess:
            break

        case let .openSystemSettings(urlString):
            guard let url = URL(string: urlString) else {
                return
            }
            NSWorkspace.shared.open(url)

        case let .openExternalURL(urlString):
            guard let url = URL(string: urlString) else {
                return
            }
            NSWorkspace.shared.open(url)

        case .openShortcutsApp:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
            }

        case .openNotesApp:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Notes.app"))
            }

        case .openMailApp:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") {
                NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: NSWorkspace.OpenConfiguration()
                ) { _, _ in }
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mail.app"))
            }
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

    private func magicianPlannerModelConfiguration(
        enabledFeatures: Set<MagicianFeatureID>,
        selectionText: String
    ) -> TextGenerationProviderConfiguration {
        let normalizedSelection = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if enabledFeatures == [.feishuCLI], normalizedSelection.isEmpty {
            return providerSettingsStore.cliRewriteConfiguration
        }
        return providerSettingsStore.rewriteConfiguration
    }

    private func magicianStepModelConfiguration(feature: MagicianFeatureID) -> TextGenerationProviderConfiguration {
        feature == .feishuCLI
            ? providerSettingsStore.cliRewriteConfiguration
            : providerSettingsStore.rewriteConfiguration
    }

    private func resolvedLane(context: WakeInvocationContext) -> InputLane {
        switch context.source {
        case .dictationTap:
            return .directDictation
        case .magicianHold:
            return .selectionRewrite
        }
    }

    private func currentMagicianDependenciesSnapshot() -> MagicianDependencySnapshot {
        let shortcutSupport = MagicianCreateNoteShortcutSupport()
        let feishuAvailability = FeishuCLIProvider.detectAvailability()
        return MagicianDependencySnapshot(
            accessibilityState: permissionsCenter.snapshot.accessibility,
            eventAuthorizationStatus: EKEventStore.authorizationStatus(for: .event),
            shortcutsCLIAvailable: shortcutSupport.cliAvailable,
            createNoteShortcutName: shortcutSupport.shortcutName,
            createNoteShortcutExists: shortcutSupport.hasShortcut(),
            notesAppAvailable: MagicianNotesCapability.notesAppAvailable,
            composeEmailAvailable: MagicianMailCapability.composeEmailServiceAvailable,
            mailtoAvailable: MagicianMailCapability.mailtoAvailable,
            mailAppAvailable: MagicianMailCapability.mailAppAvailable,
            feishuCLIAvailable: feishuAvailability.isAvailable,
            feishuCLICommandName: feishuAvailability.commandName
        )
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
