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
        contextDetector: ContextDetector
    ) {
        self.sessionStore = sessionStore
        self.permissionsCenter = permissionsCenter
        self.audioCaptureService = audioCaptureService
        self.providerSettingsStore = providerSettingsStore
        self.providerRegistry = providerRegistry
        self.rewriteProviderRegistry = rewriteProviderRegistry
        self.textOutputCoordinator = textOutputCoordinator
        self.contextDetector = contextDetector
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
                providerName: configuration.providerID.displayName,
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
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        discardPendingClipIfNeeded()
        sessionStore.cancel()
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

            do {
                guard providerSettingsStore.isConfigurationValid else {
                    throw SpeechTranscriptionError.providerFailure(
                        description: providerSettingsStore.configurationValidationMessage ?? "Provider configuration is invalid."
                    )
                }

                let configuration = providerSettingsStore.configuration
                guard let provider = providerRegistry.provider(for: configuration.providerID) else {
                    throw SpeechTranscriptionError.providerFailure(description: "Selected provider is not available in this build.")
                }

                guard
                    let apiKey = try providerSettingsStore.loadAPIKeyForActiveProvider(),
                    !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw SpeechTranscriptionError.missingAPIKey(providerName: configuration.providerID.displayName)
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
                sessionStore.fail(message: actionableMessage(for: speechError))
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                audioCaptureService.removeClip(at: clip.fileURL)
                sessionStore.clearPendingClipReference()
                sessionStore.fail(message: actionableMessage(for: .providerFailure(description: error.localizedDescription)))
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
        } catch let outputError as TextOutputError {
            sessionStore.fail(message: actionableOutputMessage(for: outputError, focusContext: focusContext))
        } catch {
            sessionStore.fail(message: actionableOutputMessage(
                for: .accessibilityPathFailed(reason: error.localizedDescription),
                focusContext: focusContext
            ))
        }
    }

    private func outputSelectionRewrite(
        _ transcription: SpeechTranscriptionResult
    ) async {
        let spokenInstruction = transcription.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenInstruction.isEmpty else {
            sessionStore.fail(message: "Rewrite instruction is empty. Please try again with a clear command.")
            return
        }

        let quickActionLabel = (try? RewriteIntentParser().parse(instruction: spokenInstruction).action.label)

        guard let snapshot = textOutputCoordinator.currentSelectionSnapshot() else {
            sessionStore.fail(message: "No selected text detected. Select text first, then trigger rewrite.")
            return
        }

        guard providerSettingsStore.isRewriteConfigurationValid else {
            sessionStore.fail(
                message: providerSettingsStore.rewriteConfigurationValidationMessage
                    ?? "Rewrite model configuration is invalid."
            )
            return
        }

        guard let loadedKey = try? providerSettingsStore.loadAPIKeyForActiveProvider() else {
            sessionStore.fail(message: "Provider API key is missing. Open Settings to add it.")
            return
        }

        let normalizedKey = loadedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            sessionStore.fail(message: "Provider API key is missing. Open Settings to add it.")
            return
        }

        let rewriteConfiguration = providerSettingsStore.rewriteConfiguration
        guard let rewriteProvider = rewriteProviderRegistry.provider(for: rewriteConfiguration.providerID) else {
            sessionStore.fail(message: "Selected rewrite provider is not available in this build.")
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
        } catch let rewriteError as RewriteProviderError {
            sessionStore.fail(message: actionableRewriteMessage(for: rewriteError))
        } catch let outputError as TextOutputError {
            sessionStore.fail(message: actionableOutputMessage(for: outputError, focusContext: snapshot.focusContext))
        } catch {
            sessionStore.fail(message: "Rewrite failed: \(error.localizedDescription)")
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
}
