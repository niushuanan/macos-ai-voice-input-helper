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
    private var cancellables = Set<AnyCancellable>()

    init(
        sessionStore: SessionStore,
        permissionsCenter: PermissionsCenter,
        audioCaptureService: AudioCaptureService
    ) {
        self.sessionStore = sessionStore
        self.permissionsCenter = permissionsCenter
        self.audioCaptureService = audioCaptureService
        bindListeningLevel()
    }

    func handleWakeInput(context: WakeInvocationContext = .dictation) {
        permissionsCenter.refreshStatuses()

        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            guard permissionsCenter.snapshot.canStartVoiceSession else {
                sessionStore.fail(message: "Microphone permission is required before starting a voice session.")
                return
            }

            if context.rewriteModifierHeld && context.selectionAvailable {
                guard permissionsCenter.snapshot.accessibility == .granted else {
                    sessionStore.fail(message: "Accessibility permission is required for selection rewrite.")
                    return
                }
                startRecordingAndTransition(lane: .selectionRewrite)
            } else {
                startRecordingAndTransition(lane: .directDictation)
            }
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
            sessionStore.attachPendingClip(clip)
            sessionStore.updateListeningLevel(0)
            sessionStore.markTranscribing(audioSummary: clip.displaySummary)
        } catch {
            sessionStore.fail(message: "Recording could not stop cleanly: \(error.localizedDescription)")
        }
    }

    func handleCancelInput() {
        guard sessionStore.phase != .idle else {
            return
        }
        if audioCaptureService.isRecording {
            audioCaptureService.cancelRecording()
        }
        if let clip = sessionStore.pendingClip {
            audioCaptureService.removeClip(at: clip.fileURL)
        }
        sessionStore.cancel()
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
}
