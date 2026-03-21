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

    init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
    }

    func handleWakeInput(context: WakeInvocationContext = .dictation) {
        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            if context.rewriteModifierHeld && context.selectionAvailable {
                sessionStore.startRewrite()
            } else {
                sessionStore.startDictation()
            }
        case .listening:
            sessionStore.markTranscribing()
        case .transcribing, .rewriting, .inserting:
            break
        }
    }

    func handleStopInput() {
        guard sessionStore.phase == .listening else {
            return
        }
        sessionStore.markTranscribing()
    }

    func handleCancelInput() {
        guard sessionStore.phase != .idle else {
            return
        }
        sessionStore.cancel()
    }
}
