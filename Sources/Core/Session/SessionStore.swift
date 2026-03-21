import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var activeLane: InputLane = .directDictation
    @Published private(set) var statusMessage: String = "Ready for a keyboard-first voice session."
    @Published private(set) var errorMessage: String?
    @Published private(set) var listeningLevel: Double = 0
    @Published private(set) var pendingClip: RecordedAudioClip?
    @Published private(set) var latestTranscription: SpeechTranscriptionResult?
    @Published private(set) var latestFocusContext: FocusedAppContext?
    @Published private(set) var latestOutputResult: TextOutputResult?

    private let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.listening],
        .listening: [.transcribing, .cancelled, .error],
        .transcribing: [.idle, .rewriting, .inserting, .cancelled, .error],
        .rewriting: [.inserting, .cancelled, .error],
        .inserting: [.idle, .cancelled, .error],
        .cancelled: [.idle, .listening],
        .error: [.idle, .listening]
    ]

    func startDictation() {
        pendingClip = nil
        listeningLevel = 0
        activeLane = .directDictation
        transition(to: .listening, statusMessage: "Listening for direct dictation.")
    }

    func startRewrite() {
        pendingClip = nil
        listeningLevel = 0
        activeLane = .selectionRewrite
        transition(to: .listening, statusMessage: "Listening for rewrite intent on the current selection.")
    }

    func markTranscribing(audioSummary: String? = nil) {
        if let audioSummary {
            transition(to: .transcribing, statusMessage: "Audio ready: \(audioSummary)")
        } else {
            transition(to: .transcribing, statusMessage: "Turning speech into a structured text request.")
        }
    }

    func markTranscribing(
        audioSummary: String,
        providerName: String,
        modelName: String
    ) {
        transition(
            to: .transcribing,
            statusMessage: "Transcribing \(audioSummary) with \(providerName) · \(modelName)."
        )
    }

    func completeTranscription(result: SpeechTranscriptionResult) {
        latestTranscription = result
    }

    func markInserting(
        transcription result: SpeechTranscriptionResult,
        focusContext: FocusedAppContext
    ) {
        latestTranscription = result
        latestFocusContext = focusContext
        transition(
            to: .inserting,
            statusMessage: "Writing transcript into \(focusContext.appName)."
        )
    }

    func completeInsertion(outputResult: TextOutputResult) {
        latestOutputResult = outputResult
        pendingClip = nil
        listeningLevel = 0
        let pathTitle = outputResult.usedFallback ? "fallback paste path" : "direct AX path"
        transition(to: .idle, statusMessage: "Text written to \(outputResult.appName) via \(pathTitle).")
    }

    func markRewriting() {
        activeLane = .selectionRewrite
        transition(to: .rewriting, statusMessage: "Applying rewrite instructions to the selected text.")
    }

    func markInserting() {
        transition(to: .inserting, statusMessage: "Handing the final text back to the focused app.")
    }

    func completeInsertion() {
        pendingClip = nil
        listeningLevel = 0
        transition(to: .idle, statusMessage: "Ready for the next voice session.")
    }

    func cancel() {
        pendingClip = nil
        listeningLevel = 0
        errorMessage = nil
        phase = .cancelled
        statusMessage = "Session cancelled without changing the target app."
    }

    func fail(message: String) {
        listeningLevel = 0
        errorMessage = message
        phase = .error
        statusMessage = message
    }

    func reset() {
        pendingClip = nil
        listeningLevel = 0
        errorMessage = nil
        phase = .idle
        statusMessage = "Ready for a keyboard-first voice session."
    }

    func updateListeningLevel(_ level: Double) {
        let clamped = max(0, min(1, level))
        listeningLevel = clamped
    }

    func attachPendingClip(_ clip: RecordedAudioClip) {
        pendingClip = clip
    }

    func clearPendingClipReference() {
        pendingClip = nil
    }

    private func transition(to nextPhase: SessionPhase, statusMessage: String) {
        guard phase == nextPhase || allowedTransitions[phase, default: []].contains(nextPhase) else {
            return
        }

        errorMessage = nil
        phase = nextPhase
        self.statusMessage = statusMessage
    }
}
