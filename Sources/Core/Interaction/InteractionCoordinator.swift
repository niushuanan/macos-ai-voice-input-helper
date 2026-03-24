import AppKit
import Combine
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
    let appliedSkills: [SkillRuleID]
    let nonBlockingNotice: String?
}

private enum DictationRoute {
    case asrOnly
    case asrAndTextProcessing
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
    private let skillRuleStore: SkillRuleStore
    private let asrDictionaryStore: ASRDictionaryStore
    private let toastPresenter: ToastPresenter?
    private let dictationPostProcessor: DictationPostProcessor
    private let brainstormContextComposer: BrainstormContextComposer
    private var cancellables = Set<AnyCancellable>()
    private var transcriptionTask: Task<Void, Never>?
    private var currentDictationTarget: DictationWritebackTarget?
    private var lastExternalDictationTarget: DictationWritebackTarget?
    private var lastDictionaryTruncationSignature: Int?

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
        skillRuleStore: SkillRuleStore,
        asrDictionaryStore: ASRDictionaryStore,
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
        self.skillRuleStore = skillRuleStore
        self.asrDictionaryStore = asrDictionaryStore
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
                return
            }
            handleStopInput()
        case .transcribing, .rewriting, .inserting:
            break
        }
    }

    func handleStopInput() {
        guard sessionStore.phase == .listening else {
            return
        }
        let configuration = providerSettingsStore.configuration
        // 先切到转写阶段，避免 stopRecording 收尾期间 HUD 停在“聆听中”造成卡顿感。
        sessionStore.markTranscribing()
        do {
            let clip = try audioCaptureService.stopRecording()
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
            sessionStore.fail(message: "停止录音失败：\(error.localizedDescription)")
        }
    }

    func handleCancelInput() {
        guard sessionStore.phase != .idle else {
            return
        }

        let focusContext = contextDetector.focusedAppContext()
        let mode = historyMode(for: sessionStore.activeLane)
        let latestInput = sessionStore.latestTranscription?.transcript ?? ""
        let clipDuration = sessionStore.pendingClip?.duration

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
    }

    func handleCompleteInput() {
        guard sessionStore.phase == .inserting else {
            return
        }
        currentDictationTarget = nil
        discardPendingClipIfNeeded()
        sessionStore.completeInsertion()
    }

    func handleResetInput() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentDictationTarget = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.reset()
    }

    private func startRecordingAndTransition(lane: InputLane) {
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
        } catch {
            currentDictationTarget = nil
            sessionStore.fail(message: "无法开始录音：\(error.localizedDescription)")
        }
    }

    private func startTranscription(for clip: RecordedAudioClip) {
        transcriptionTask?.cancel()

        transcriptionTask = Task { [weak self] in
            guard let self else {
                return
            }

            var resolvedConfiguration: SpeechProviderConfiguration?

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

                let result = try await provider.transcribe(
                    request: request,
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else {
                    return
                }

                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                await processTranscriptionResult(
                    result,
                    lane: request.lane,
                    audioDurationSeconds: clip.duration
                )
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
                sessionStore.fail(message: actionableMessage(for: speechError))
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
                sessionStore.fail(message: message)
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
            currentDictationTarget = nil
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
            currentDictationTarget = nil
            sessionStore.fail(message: message)
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
            currentDictationTarget = nil
            sessionStore.fail(message: message)
        }
    }

    private func outputBrainstormContext(
        _ transcription: SpeechTranscriptionResult,
        audioDurationSeconds: TimeInterval
    ) async {
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
            userSystemPrompt: userSystemPrompt.isEmpty ? nil : userSystemPrompt
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
            currentDictationTarget = nil
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
            currentDictationTarget = nil
            sessionStore.fail(message: message)
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
            currentDictationTarget = nil
            sessionStore.fail(message: message)
        }
    }

    private func composeBrainstormContext(
        transcript: String,
        focusContext: FocusedAppContext,
        appPrompt: String?,
        userSystemPrompt: String?
    ) async -> BrainstormComposeOutcome {
        let normalizedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            return makeFallbackBrainstormOutcome(
                transcript: "",
                notice: "转写文本为空，已给出最小模板。"
            )
        }

        let normalizedSystemPrompt = userSystemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAppPrompt = appPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard providerSettingsStore.isRewriteConfigurationValid else {
            let message = providerSettingsStore.rewriteConfigurationValidationMessage
                ?? "文本模型配置无效。"
            return makeFallbackBrainstormOutcome(
                transcript: normalizedTranscript,
                notice: "文本模型暂不可用（\(message)），已给出基础模板。"
            )
        }

        guard
            let loadedKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider(),
            !loadedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return makeFallbackBrainstormOutcome(
                transcript: normalizedTranscript,
                notice: "文本模型密钥不可用，已给出基础模板。"
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
            return BrainstormComposeOutcome(
                summaryText: result.summaryText,
                dialogueText: result.dialogueText,
                rewriteProvider: result.providerName,
                rewriteModel: result.modelName,
                appliedSkills: modelAppliedSkills,
                nonBlockingNotice: nil
            )
        } catch {
            return makeFallbackBrainstormOutcome(
                transcript: normalizedTranscript,
                notice: "上下文整理失败，已回退到基础模板。"
            )
        }
    }

    private func makeFallbackBrainstormOutcome(
        transcript: String,
        notice: String
    ) -> BrainstormComposeOutcome {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText = fallbackBrainstormSummary(transcript: normalized)
        let dialogueText = fallbackBrainstormDialogue(transcript: normalized)
        return BrainstormComposeOutcome(
            summaryText: summaryText,
            dialogueText: dialogueText,
            rewriteProvider: nil,
            rewriteModel: nil,
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
        let rawInstruction = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructionApplyResult = skillRuleStore.applyRewriteInstruction(rawInstruction)
        let processedInstruction = instructionApplyResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenInstruction = processedInstruction.isEmpty ? rawInstruction : processedInstruction
        let initialFocusContext = contextDetector.focusedAppContext()
        let scenePolicy = effectiveScenePolicy(for: initialFocusContext)
        let activeSystemPrompt = skillRuleStore.activeSystemPrompt()
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
            sessionStore.fail(message: message)
            return
        }

        let quickActionLabel = (try? RewriteIntentParser().parse(
            instruction: spokenInstruction,
            defaultOutputBias: .neutral
        ).action.label)

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
            sessionStore.fail(message: message)
            return
        }

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
            sessionStore.fail(
                message: message
            )
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
            sessionStore.completeInsertion(outputResult: outputResult)
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
            sessionStore.fail(message: message)
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
            sessionStore.fail(message: message)
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
            sessionStore.fail(message: message)
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
        return .directDictation
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
