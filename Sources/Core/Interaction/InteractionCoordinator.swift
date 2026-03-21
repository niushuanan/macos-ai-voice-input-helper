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
    private let localHistoryStore: LocalHistoryStore
    private var cancellables = Set<AnyCancellable>()
    private var transcriptionTask: Task<Void, Never>?

    init(
        sessionStore: SessionStore,
        permissionsCenter: PermissionsCenter,
        audioCaptureService: AudioCaptureService,
        providerSettingsStore: ProviderSettingsStore,
        providerRegistry: SpeechProviderRegistry,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        contextDetector: ContextDetector,
        localHistoryStore: LocalHistoryStore
    ) {
        self.sessionStore = sessionStore
        self.permissionsCenter = permissionsCenter
        self.audioCaptureService = audioCaptureService
        self.providerSettingsStore = providerSettingsStore
        self.providerRegistry = providerRegistry
        self.rewriteProviderRegistry = rewriteProviderRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
        self.localHistoryStore = localHistoryStore
        bindListeningLevel()
    }

    func handleWakeInput(context: WakeInvocationContext = .dictation) {
        permissionsCenter.refreshStatuses()

        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            discardPendingClipIfNeeded()

            guard permissionsCenter.snapshot.canStartVoiceSession else {
                sessionStore.fail(message: "Microphone permission is required before starting a voice session.")
                return
            }

            let lane = resolvedLane(context: context)
            if lane == .selectionRewrite && permissionsCenter.snapshot.accessibility != .granted {
                sessionStore.fail(message: "Accessibility permission is required for selection rewrite.")
                return
            }
            startRecordingAndTransition(lane: lane)
        case .listening:
            handleStopInput()
        case .transcribing, .rewriting, .inserting:
            break
        }
    }

    func handleStopInput() {
        guard sessionStore.phase == .listening else {
            return
        }
        do {
            let clip = try audioCaptureService.stopRecording()
            discardPendingClipIfNeeded()
            sessionStore.attachPendingClip(clip)
            sessionStore.updateListeningLevel(0)
            let configuration = providerSettingsStore.configuration
            sessionStore.markTranscribing(
                audioSummary: clip.displaySummary,
                providerName: configuration.providerName,
                modelName: configuration.modelName
            )
            startTranscription(for: clip)
        } catch {
            sessionStore.fail(message: "Recording could not stop cleanly: \(error.localizedDescription)")
        }
    }

    func handleCancelInput() {
        guard sessionStore.phase != .idle else {
            return
        }

        let focusContext = contextDetector.focusedAppContext()
        let mode = historyMode(for: sessionStore.activeLane)
        let latestInput = sessionStore.latestTranscription?.transcript ?? ""

        transcriptionTask?.cancel()
        transcriptionTask = nil

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
                errorMessage: "User cancelled the current session."
            )
        )
    }

    func handleCompleteInput() {
        guard sessionStore.phase == .inserting else {
            return
        }
        discardPendingClipIfNeeded()
        sessionStore.completeInsertion()
    }

    func handleResetInput() {
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.reset()
    }

    private func startRecordingAndTransition(lane: InputLane) {
        do {
            try audioCaptureService.startRecording()
            switch lane {
            case .directDictation:
                sessionStore.startDictation()
            case .selectionRewrite:
                sessionStore.startRewrite()
            }
        } catch {
            sessionStore.fail(message: "Recording could not start: \(error.localizedDescription)")
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
                        description: providerSettingsStore.configurationValidationMessage ?? "Provider configuration is invalid."
                    )
                }

                let configuration = providerSettingsStore.configuration
                resolvedConfiguration = configuration
                guard let provider = providerRegistry.provider(for: configuration.providerType) else {
                    throw SpeechTranscriptionError.providerFailure(description: "Selected provider is not available in this build.")
                }

                guard
                    let apiKey = try providerSettingsStore.loadAPIKeyForTranscriptionProvider(),
                    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw SpeechTranscriptionError.missingAPIKey(providerName: configuration.providerName)
                }

                let request = SpeechTranscriptionRequest(
                    clip: clip,
                    lane: sessionStore.activeLane,
                    contextSummary: "lane=\(sessionStore.activeLane.rawValue)"
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
                await processTranscriptionResult(result, lane: request.lane)
            } catch is CancellationError {
                return
            } catch let speechError as SpeechTranscriptionError {
                guard !Task.isCancelled else {
                    return
                }
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
                        errorMessage: actionableMessage(for: speechError)
                    )
                )
                sessionStore.fail(message: actionableMessage(for: speechError))
            } catch {
                guard !Task.isCancelled else {
                    return
                }
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
                        errorMessage: message
                    )
                )
                sessionStore.fail(message: message)
            }
        }
    }

    private func processTranscriptionResult(
        _ transcription: SpeechTranscriptionResult,
        lane: InputLane
    ) async {
        switch lane {
        case .directDictation:
            await outputDictationTranscript(transcription)
        case .selectionRewrite:
            await outputSelectionRewrite(transcription)
        }
    }

    private func outputDictationTranscript(
        _ transcription: SpeechTranscriptionResult
    ) async {
        let focusContext = contextDetector.focusedAppContext()

        let request = TextOutputRequest(
            text: transcription.transcript,
            operation: .insertText,
            focusContext: focusContext
        )

        sessionStore.markInserting(
            transcription: transcription,
            focusContext: focusContext
        )

        do {
            let outputResult = try await textOutputCoordinator.write(request: request)
            sessionStore.completeInsertion(outputResult: outputResult)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .dictation,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: transcription.transcript,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .success
                )
            )
        } catch let outputError as TextOutputError {
            let message = actionableOutputMessage(for: outputError, focusContext: focusContext)
            localHistoryStore.append(
                SessionHistoryEntry(
                    mode: .dictation,
                    appName: focusContext.appName,
                    bundleID: focusContext.bundleID,
                    inputText: transcription.transcript,
                    outputText: nil,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message
                )
            )
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
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    status: .failed,
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
        }
    }

    private func outputSelectionRewrite(
        _ transcription: SpeechTranscriptionResult
    ) async {
        let spokenInstruction = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialFocusContext = contextDetector.focusedAppContext()
        guard !spokenInstruction.isEmpty else {
            let message = "Rewrite instruction is empty. Please try again with a clear command."
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
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
            return
        }

        let quickActionLabel = (try? RewriteIntentParser().parse(instruction: spokenInstruction).action.label)

        guard let snapshot = textOutputCoordinator.currentSelectionSnapshot() else {
            let message = "No selected text detected. Select text first, then trigger rewrite."
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
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
            return
        }

        guard providerSettingsStore.isRewriteConfigurationValid else {
            let message = providerSettingsStore.rewriteConfigurationValidationMessage
                ?? "Rewrite model configuration is invalid."
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
                    errorMessage: message
                )
            )
            sessionStore.fail(
                message: message
            )
            return
        }

        guard let loadedKey = try? providerSettingsStore.loadAPIKeyForRewriteProvider() else {
            let message = "Provider API key is missing. Open Settings to add it."
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
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
            return
        }

        let normalizedKey = loadedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            let message = "Provider API key is missing. Open Settings to add it."
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
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
            return
        }

        let rewriteConfiguration = providerSettingsStore.rewriteConfiguration
        guard let rewriteProvider = rewriteProviderRegistry.provider(for: rewriteConfiguration.providerType) else {
            let message = "Selected rewrite provider is not available in this build."
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
                    errorMessage: message
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
                    focusContext: snapshot.focusContext
                ),
                configuration: rewriteConfiguration,
                apiKey: normalizedKey
            )

            let outputRequest = TextOutputRequest(
                text: rewriteResult.rewrittenText,
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
                    outputText: rewriteResult.rewrittenText,
                    instructionText: spokenInstruction,
                    transcriptionProvider: transcription.providerName,
                    transcriptionModel: transcription.modelName,
                    rewriteProvider: rewriteResult.providerName,
                    rewriteModel: rewriteResult.modelName,
                    status: .success
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
                    errorMessage: message
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
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
        } catch {
            let message = "Rewrite failed: \(error.localizedDescription)"
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
                    errorMessage: message
                )
            )
            sessionStore.fail(message: message)
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
            return "\(providerName) API key is missing. Open Settings -> Provider to add it."
        case let .networkFailure(description):
            return "Network issue while transcribing. Check connection and retry. (\(description))"
        case let .providerFailure(description):
            return "Transcription provider rejected the request. Verify key, model, and quota. (\(description))"
        case let .audioFormatUnsupported(fileExtension):
            return "Recorded audio format \(fileExtension) is unsupported. Restart recording and try again."
        case .invalidResponse:
            return "Provider response could not be parsed. Retry once, then change model if needed."
        case .cancelled:
            return "Transcription was cancelled."
        }
    }

    private func actionableOutputMessage(
        for error: TextOutputError,
        focusContext: FocusedAppContext
    ) -> String {
        switch error {
        case .emptyText:
            return "Transcription returned empty text. Please try speaking again."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for direct insertion into \(focusContext.appName)."
        case .noFocusedElement:
            return "No focused input target in \(focusContext.appName). Click an editor and try again."
        case .noEditableTarget:
            return "Focused target in \(focusContext.appName) is not editable."
        case let .accessibilityPathFailed(reason):
            return "Direct insertion failed in \(focusContext.appName): \(reason)"
        case .pasteboardUnavailable:
            return "Fallback paste path is unavailable because pasteboard access failed."
        case .pasteShortcutInjectionFailed:
            return "Fallback paste path could not send Command+V."
        case let .fallbackFailed(primaryReason):
            return "Writeback failed in \(focusContext.appName). Direct path reason: \(primaryReason)"
        }
    }

    private func actionableRewriteMessage(for error: RewriteProviderError) -> String {
        switch error {
        case .noSelectedText:
            return "No selected text is available for rewrite."
        case .emptyInstruction:
            return "Instruction is empty. Try a command like translate, polish, condense, or structure."
        case let .generationFailed(description):
            return "Rewrite model request failed. Check model/key/quota. (\(description))"
        case .invalidGeneratedText:
            return "Rewrite model returned empty text. Please try a clearer command."
        }
    }

    private func resolvedLane(context: WakeInvocationContext) -> InputLane {
        if context.rewriteModifierHeld && context.selectionAvailable {
            return .selectionRewrite
        }

        if textOutputCoordinator.currentSelectionSnapshot() != nil {
            return .selectionRewrite
        }

        return .directDictation
    }

    private func historyMode(for lane: InputLane) -> SessionHistoryMode {
        switch lane {
        case .directDictation:
            return .dictation
        case .selectionRewrite:
            return .selectionRewrite
        }
    }
}
