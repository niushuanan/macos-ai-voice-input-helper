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

    init(sessionStore: SessionStore, permissionsCenter: PermissionsCenter) {
        self.sessionStore = sessionStore
        self.permissionsCenter = permissionsCenter
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
