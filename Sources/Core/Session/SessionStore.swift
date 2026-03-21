import Combine
import Foundation

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var activeLane: InputLane = .directDictation
    @Published private(set) var statusMessage: String = "Ready for a keyboard-first voice session."
    @Published private(set) var errorMessage: String?

    private let allowedTransitions: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.listening],
        .listening: [.transcribing, .cancelled, .error],
        .transcribing: [.rewriting, .inserting, .cancelled, .error],
        .rewriting: [.inserting, .cancelled, .error],
        .inserting: [.idle, .cancelled, .error],
        .cancelled: [.idle, .listening],
        .error: [.idle, .listening]
    ]

    func startDictation() {
        activeLane = .directDictation
        transition(to: .listening, statusMessage: "Listening for direct dictation.")
    }

    func startRewrite() {
        activeLane = .selectionRewrite
        transition(to: .listening, statusMessage: "Listening for rewrite intent on the current selection.")
    }

    func markTranscribing() {
        transition(to: .transcribing, statusMessage: "Turning speech into a structured text request.")
    }

    func markRewriting() {
        activeLane = .selectionRewrite
        transition(to: .rewriting, statusMessage: "Applying rewrite instructions to the selected text.")
    }

    func markInserting() {
        transition(to: .inserting, statusMessage: "Handing the final text back to the focused app.")
    }

    func completeInsertion() {
        transition(to: .idle, statusMessage: "Ready for the next voice session.")
    }

    func cancel() {
        errorMessage = nil
        phase = .cancelled
        statusMessage = "Session cancelled without changing the target app."
    }

    func fail(message: String) {
        errorMessage = message
        phase = .error
        statusMessage = message
    }

    func reset() {
        errorMessage = nil
        phase = .idle
        statusMessage = "Ready for a keyboard-first voice session."
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
