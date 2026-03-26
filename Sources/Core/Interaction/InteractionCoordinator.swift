import AppKit
import Combine
import EventKit
import Foundation

struct WakeInvocationContext: Equatable {
    let rewriteModifierHeld: Bool
    let selectionAvailable: Bool

    static let dictation = WakeInvocationContext(
        rewriteModifierHeld: false,
        selectionAvailable: false
    )
}

struct DictationWritebackTarget: Equatable {
    let focusContext: FocusedAppContext
    let processIdentifier: pid_t?

    var snapshot: WritebackTargetSnapshot {
        WritebackTargetSnapshot(
            appName: focusContext.appName,
            bundleID: focusContext.bundleID,
            processIdentifier: processIdentifier
        )
    }
}

private struct DictationPostProcessOutcome {
    let route: DictationRoute
    let text: String
    let appliedSkills: [SkillRuleID]
    let nonBlockingNotice: String?
}

private struct BrainstormComposeOutcome {
    let summaryText: String
    let dialogueText: String
    let rewriteProvider: String?
    let rewriteModel: String?
    let tokenBudget: Int?
    let appliedSkills: [SkillRuleID]
    let nonBlockingNotice: String?
}

private enum DictationRoute {
    case asrOnly
    case asrAndTextProcessing
}

private struct ASRTranscriptionOutcome {
    let result: SpeechTranscriptionResult
    let attempts: Int
}

private struct ASRTranscriptionFailure: Error {
    let error: SpeechTranscriptionError
    let attempts: Int
}

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
    private let magicianIntentRouter: any MagicianIntentRouting
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
        magicianFeatureToggleStore: MagicianFeatureToggleStore? = nil,
        magicianStatusResolver: MagicianStatusResolver = MagicianStatusResolver(),
        magicianIntentRouter: (any MagicianIntentRouting)? = nil,
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
        self.magicianIntentRouter = magicianIntentRouter ?? LLMMagicianIntentRouter(
            providerSettingsStore: providerSettingsStore
        )
        self.magicianToolExecutor = magicianToolExecutor ?? MagicianToolExecutor()
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

            let lane = resolvedLane(context: context)
            startRecordingAndTransition(lane: lane)
        case .listening:
            handleStopInput()
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

    private func ensureTraceID() -> String {
        if let currentTraceID {
            return currentTraceID
        }
        let newTraceID = UUID().uuidString
        currentTraceID = newTraceID
        return newTraceID
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
                    httpStatus: httpStatus(from: speechError),
                    stage: "asr.attempt.failed",
                    errorType: transcriptionErrorType(for: speechError),
                    detail: actionableMessage(for: speechError),
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
                    httpStatus: httpStatus(from: wrapped),
                    stage: "asr.attempt.failed",
                    errorType: transcriptionErrorType(for: wrapped),
                    detail: actionableMessage(for: wrapped),
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

    private func finalTranscriptionErrorMessage(
        for error: SpeechTranscriptionError,
        traceID: String,
        attempts: Int
    ) -> String {
        let message = actionableMessage(for: error)
        if case .invalidResponse = error, attempts >= 2 {
            return "\(message)（traceID: \(traceID)）"
        }
        return message
    }

    private func transcriptionErrorType(for error: SpeechTranscriptionError) -> String {
        switch error {
        case .missingAPIKey:
            return "missingAPIKey"
        case .audioFormatUnsupported:
            return "audioFormatUnsupported"
        case .networkFailure:
            return "networkFailure"
        case .providerFailure:
            return "providerFailure"
        case .invalidResponse:
            return "invalidResponse"
        case .cancelled:
            return "cancelled"
        }
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
                        httpStatus: httpStatus(from: speechError),
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
                    httpStatus: httpStatus(from: speechError),
                    stage: "brainstorm.probe.attempt.failed",
                    errorType: transcriptionErrorType(for: speechError),
                    detail: "durationSeconds=\(durationSeconds),\(actionableMessage(for: speechError))"
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

    private func httpStatus(from error: SpeechTranscriptionError) -> Int? {
        switch error {
        case let .networkFailure(description):
            return httpStatus(from: description)
        case let .providerFailure(description):
            return httpStatus(from: description)
        case .missingAPIKey, .audioFormatUnsupported, .invalidResponse, .cancelled:
            return nil
        }
    }

    private func httpStatus(from text: String) -> Int? {
        guard
            let regex = try? NSRegularExpression(pattern: #"HTTP\s+(\d{3})"#, options: .caseInsensitive),
            let match = regex.firstMatch(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[range])
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

                let dictionarySnapshot = asrDictionaryStore.currentSnapshot()
                notifyIfDictionaryTruncated(snapshot: dictionarySnapshot)

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
                let message = finalTranscriptionErrorMessage(
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
                    httpStatus: httpStatus(from: failure.error),
                    stage: "asr.failed",
                    errorType: transcriptionErrorType(for: failure.error),
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
                        errorMessage: actionableMessage(for: speechError),
                        audioDurationSeconds: clip.duration
                    )
                )
                speechPipelineLogger.log(
                    traceID: traceID,
                    lane: lane,
                    provider: resolvedConfiguration?.providerName,
                    model: resolvedConfiguration?.modelName,
                    httpStatus: httpStatus(from: speechError),
                    stage: "asr.failed",
                    errorType: transcriptionErrorType(for: speechError),
                    detail: actionableMessage(for: speechError),
                    audioDuration: clip.duration
                )
                sessionStore.fail(message: actionableMessage(for: speechError))
                currentTraceID = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                currentDictationTarget = nil
                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                let message = actionableMessage(for: .providerFailure(description: error.localizedDescription))
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
                    httpStatus: httpStatus(from: message),
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
                httpStatus: httpStatus(from: message),
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
        let summaryText = fallbackBrainstormSummary(transcript: normalized)
        let dialogueText = fallbackBrainstormDialogue(transcript: normalized)
        return BrainstormComposeOutcome(
            summaryText: summaryText,
            dialogueText: dialogueText,
            rewriteProvider: nil,
            rewriteModel: nil,
            tokenBudget: tokenBudget,
            appliedSkills: [],
            nonBlockingNotice: notice
        )
    }

    private func fallbackBrainstormSummary(transcript: String) -> String {
        var points = [
            "先确认讨论目标与边界，再推进执行。",
            "优先完成最小可行版本，复杂项后置。",
            "按优先级拆分任务并明确负责人。"
        ]
        if let firstLine = transcript
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        {
            points[0] = "本次讨论核心为：\(firstLine.prefix(28))。"
        }
        return points.map { "- \($0)" }.joined(separator: "\n")
    }

    private func fallbackBrainstormDialogue(transcript: String) -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return "A: （暂无有效转写内容）"
        }

        let rawLines = normalized
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let roles = ["A", "B", "C"]
        let lines = rawLines.isEmpty ? [normalized] : rawLines

        return lines.enumerated().map { index, line in
            if line.range(of: #"^[A-Z][A-Z0-9]*\s*[:：]"#, options: .regularExpression) != nil {
                return line.replacingOccurrences(of: "：", with: ":")
            }
            return "\(roles[index % roles.count]): \(line)"
        }
        .joined(separator: "\n")
    }

    private func outputSelectionRewrite(
        _ transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval
    ) async {
        let traceID = ensureTraceID()
        let rawInstruction = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionApplyResult = skillRuleStore.applyRewriteInstruction(rawInstruction)
        let processedInstruction = instructionApplyResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenInstruction = processedInstruction.isEmpty ? rawInstruction : processedInstruction
        let initialFocusContext = contextDetector.focusedAppContext()
        guard !spokenInstruction.isEmpty else {
            let message = "改写指令为空，请重试并说出明确命令。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: initialFocusContext.appName,
                    bundleID: initialFocusContext.bundleID,
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

        guard let snapshot = textOutputCoordinator.currentSelectionSnapshot() else {
            let message = "未检测到选中文本，请先选中内容再触发改写。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: initialFocusContext.appName,
                    bundleID: initialFocusContext.bundleID,
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
                errorType: "selectionMissing",
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        let enabledFeatures = magicianFeatureToggleStore.enabledFeatures
        guard !enabledFeatures.isEmpty else {
            let message = "魔法师能力都还没开启，请先在魔法师页面打开开关。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
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

        let routedIntent: MagicianIntent
        do {
            routedIntent = try await magicianIntentRouter.route(
                command: spokenInstruction,
                selection: snapshot.selectedText,
                enabledFeatures: enabledFeatures
            )
            speechPipelineLogger.log(
                traceID: traceID,
                lane: .selectionRewrite,
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.intent.routed",
                detail: "intent=\(routedIntent.intent.rawValue),confidence=\(String(format: "%.2f", routedIntent.confidence))",
                audioDuration: audioDurationSeconds,
                transcriptLength: spokenInstruction.count
            )
        } catch let magicianError as MagicianError {
            let message = magicianError.userMessage
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
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
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.intent.failed",
                errorType: magicianError.code.rawValue,
                detail: magicianError.debugMessage ?? message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        } catch {
            let message = "指令解析失败，请换个说法再试。"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
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
                provider: providerSettingsStore.rewriteConfiguration.providerName,
                model: providerSettingsStore.rewriteConfiguration.modelName,
                httpStatus: nil,
                stage: "magician.intent.failed",
                errorType: "intent_parse_failed",
                detail: error.localizedDescription,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        permissionsCenter.refreshStatuses()
        let requirement = magicianStatusResolver.requirement(
            for: routedIntent.intent,
            dependencies: currentMagicianDependenciesSnapshot()
        )
        if case let .blocked(reason, _) = requirement {
            let message = "\(routedIntent.intent.displayName)：\(reason)"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
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
                stage: "magician.tool.failed",
                errorType: MagicianErrorCode.permissionDenied.rawValue,
                detail: message,
                audioDuration: audioDurationSeconds
            )
            sessionStore.fail(message: message)
            currentTraceID = nil
            return
        }

        if routedIntent.intent == .textTransform {
            await executeTextTransformIntent(
                transcription: transcription,
                audioDurationSeconds: audioDurationSeconds,
                spokenInstruction: spokenInstruction,
                snapshot: snapshot,
                instructionApplyResult: instructionApplyResult,
                traceID: traceID
            )
            return
        }

        await executeMagicianToolIntent(
            routedIntent,
            transcription: transcription,
            spokenInstruction: spokenInstruction,
            snapshot: snapshot,
            instructionApplyResult: instructionApplyResult,
            audioDurationSeconds: audioDurationSeconds,
            traceID: traceID
        )
    }

    private func executeTextTransformIntent(
        transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval,
        spokenInstruction: String,
        snapshot: FocusedSelectionSnapshot,
        instructionApplyResult: SkillApplyResult,
        traceID: String
    ) async {
        let scenePolicy = effectiveScenePolicy(for: snapshot.focusContext)
        let activeSystemPrompt = skillRuleStore.activeSystemPrompt()
        let quickActionLabel = (try? RewriteIntentParser().parse(
            instruction: spokenInstruction,
            defaultOutputBias: .neutral
        ).action.label)

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

        sessionStore.markRewriting(actionLabel: quickActionLabel)
        do {
            let rewriteResult = try await rewriteProvider.rewrite(
                request: SelectionRewriteRequest(
                    selectedText: snapshot.selectedText,
                    spokenInstruction: spokenInstruction,
                    focusContext: snapshot.focusContext,
                    outputBias: .neutral,
                    appPrompt: scenePolicy.appPrompt,
                    userSystemPrompt: activeSystemPrompt
                ),
                configuration: rewriteConfiguration,
                apiKey: normalizedKey
            )
            let outputApplyResult = skillRuleStore.applyRewriteOutput(
                rewriteResult.rewrittenText,
                outputBias: .neutral
            )
            let combinedSkills = mergedSkills(
                lhs: instructionApplyResult.appliedSkills,
                rhs: outputApplyResult.appliedSkills
            )
            let finalAppliedSkills = activeSystemPrompt == nil
                ? combinedSkills
                : mergedSkills(lhs: combinedSkills, rhs: [.systemPrompt])
            let finalRewriteText: String = {
                let normalized = outputApplyResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? rewriteResult.rewrittenText : normalized
            }()

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
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteResult.providerName,
                    rewriteModel: rewriteResult.modelName,
                    outputPath: outputResult.path,
                    status: .success,
                    audioDurationSeconds: audioDurationSeconds,
                    appliedSkills: finalAppliedSkills
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
            let message = actionableRewriteMessage(for: rewriteError)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
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
            let message = actionableOutputMessage(for: outputError, focusContext: snapshot.focusContext)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
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
            let message = "改写失败：\(error.localizedDescription)"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: nil,
                    instructionText: spokenInstruction,
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

    private func executeMagicianToolIntent(
        _ intent: MagicianIntent,
        transcription: SpeechTranscriptionResult,
        spokenInstruction: String,
        snapshot: FocusedSelectionSnapshot,
        instructionApplyResult: SkillApplyResult,
        audioDurationSeconds: TimeInterval,
        traceID: String
    ) async {
        sessionStore.markRewriting(actionLabel: intent.intent.displayName)
        do {
            let result = try await magicianToolExecutor.execute(
                intent: intent,
                command: spokenInstruction,
                selection: snapshot
            )
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
                    outputText: result.outputText,
                    instructionText: spokenInstruction,
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
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
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
            let message = "执行失败：\(error.localizedDescription)"
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .selectionRewrite,
                    appName: snapshot.focusContext.appName,
                    bundleID: snapshot.focusContext.bundleID,
                    inputText: snapshot.selectedText,
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

    private func actionableMessage(for error: SpeechTranscriptionError) -> String {
        switch error {
        case let .missingAPIKey(providerName):
            return "\(providerName) 缺少 API 密钥，请在设置页服务商配置中填写。"
        case let .networkFailure(description):
            return "转写时出现网络问题，请检查网络后重试。（\(description)）"
        case let .providerFailure(description):
            return "转写请求失败。\(providerFailureHint(from: description))（\(description)）"
        case let .audioFormatUnsupported(fileExtension):
            return "录音格式 \(fileExtension) 不支持，请重新录音后再试。"
        case .invalidResponse:
            return "服务商返回内容无法解析，可先重试一次，仍失败请更换模型。"
        case .cancelled:
            return "转写已取消。"
        }
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
            return "改写请求失败。\(providerFailureHint(from: description))（\(description)）"
        case .invalidGeneratedText:
            return "改写结果为空，请用更清晰的命令再试一次。"
        }
    }

    private func providerFailureHint(from description: String) -> String {
        let lowered = description.lowercased()
        if lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("invalid api key") {
            return "请检查 API 密钥与服务商类型。"
        }
        if lowered.contains("403") || lowered.contains("forbidden") {
            return "请检查账号是否有该模型的调用权限。"
        }
        if lowered.contains("404") || lowered.contains("model") {
            return "请核对模型名与 base URL。"
        }
        if lowered.contains("429") || lowered.contains("rate limit") {
            return "触发频率限制，可稍后再试或切换模型/服务商。"
        }
        if lowered.contains("500") || lowered.contains("502") || lowered.contains("503") || lowered.contains("504") {
            return "服务商接口当前不稳定，请稍后再试。"
        }
        return "请检查 Key、模型、接口地址与额度。"
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
        _ = userSystemPrompt
        _ = appPrompt

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return false
        }

        if normalized.contains("<|") || normalized.contains("|>") {
            return true
        }

        if normalized.contains("  ") || normalized.contains("。。") || normalized.contains("，，") {
            return true
        }

        if normalized.count >= 80 {
            return true
        }

        let punctuationSet = CharacterSet(charactersIn: "。！？.!?,，；;：:")
        let punctuationCount = normalized.unicodeScalars.filter { punctuationSet.contains($0) }.count
        if punctuationCount == 0, normalized.count >= 24 {
            return true
        }

        let lineCount = normalized.split(whereSeparator: \.isNewline).count
        if lineCount > 1 {
            return true
        }

        return false
    }

    private func resolvedLane(context: WakeInvocationContext) -> InputLane {
        _ = context
        guard magicianFeatureToggleStore.hasAnyEnabledFeature() else {
            return .directDictation
        }
        let accessibility = permissionsCenter.snapshot.accessibility
        guard accessibility == .granted || accessibility == .notRequired else {
            return .directDictation
        }
        if textOutputCoordinator.currentSelectionSnapshot() != nil {
            return .selectionRewrite
        }
        return .directDictation
    }

    private func currentMagicianDependenciesSnapshot() -> MagicianDependencySnapshot {
        MagicianDependencySnapshot(
            accessibilityState: permissionsCenter.snapshot.accessibility,
            eventAuthorizationStatus: EKEventStore.authorizationStatus(for: .event),
            shortcutsCLIAvailable: FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts"),
            composeEmailAvailable: NSSharingService(named: .composeEmail) != nil
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
