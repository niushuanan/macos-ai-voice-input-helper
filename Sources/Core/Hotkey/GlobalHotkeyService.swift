import Foundation
import KeyboardShortcuts

@MainActor
final class GlobalHotkeyService {
    private let interactionCoordinator: InteractionCoordinator
    private var hasActivated = false

    init(interactionCoordinator: InteractionCoordinator) {
        self.interactionCoordinator = interactionCoordinator
    }

    func activate() {
        guard !hasActivated else {
            return
        }
        hasActivated = true

        KeyboardShortcuts.onKeyUp(for: .wakeSession) { [weak self] in
            self?.interactionCoordinator.handleWakeInput(context: .dictation)
        }

        KeyboardShortcuts.onKeyUp(for: .cancelSession) { [weak self] in
            self?.interactionCoordinator.handleCancelInput()
        }
    }
}
