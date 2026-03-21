import AppKit
import SwiftUI

struct MenuBarMenuView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Phase: \(model.sessionStore.phase.title)")
            .font(.caption)
        Text("Lane: \(model.sessionStore.activeLane.title)")
            .font(.caption)

        Divider()

        Button("Wake Dictation") {
            model.interactionCoordinator.handleWakeInput(context: .dictation)
        }
        .disabled(!canStartSession)

        Button("Wake Rewrite") {
            model.interactionCoordinator.handleWakeInput(
                context: WakeInvocationContext(
                    rewriteModifierHeld: true,
                    selectionAvailable: true
                )
            )
        }
        .disabled(!canStartSession)

        Button("Stop Listening") {
            model.interactionCoordinator.handleStopInput()
        }
        .disabled(model.sessionStore.phase != .listening)

        Button("Cancel Session") {
            model.interactionCoordinator.handleCancelInput()
        }
        .disabled(model.sessionStore.phase == .idle)

        Divider()

        Button("Open Command Deck") {
            openWindow(id: "command-deck")
        }

        SettingsLink {
            Text("Settings")
        }

        Button("Quit PulseType") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var canStartSession: Bool {
        switch model.sessionStore.phase {
        case .idle, .cancelled, .error:
            return true
        case .listening, .transcribing, .rewriting, .inserting:
            return false
        }
    }
}
