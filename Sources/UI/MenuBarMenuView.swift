import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuBarMenuView: View {
    let model: AppModel
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore

    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
    }

    var body: some View {
        Text("Phase: \(model.sessionStore.phase.title)")
            .font(.caption)
        Text("Lane: \(model.sessionStore.activeLane.title)")
            .font(.caption)
        Text("ASR: \(providerSettingsStore.selectedTranscriptionProviderName)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text("Rewrite: \(providerSettingsStore.selectedRewriteProviderName)")
            .font(.caption2)
            .foregroundStyle(.secondary)

        if permissionsCenter.snapshot.hasBlockingIssue {
            Divider()

            Label("Microphone permission required before start.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Button("Open Privacy Settings") {
                permissionsCenter.openSystemSettings(for: .microphone)
            }
        }

        Divider()

        Button("Wake Dictation") {
            model.interactionCoordinator.handleWakeInput(context: .dictation)
        }
        .disabled(!canStartSession)
        .globalKeyboardShortcut(.wakeSession)

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
        .globalKeyboardShortcut(.stopSession)

        Button("Cancel Session") {
            model.interactionCoordinator.handleCancelInput()
        }
        .disabled(model.sessionStore.phase == .idle)
        .globalKeyboardShortcut(.cancelSession)

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
        .onAppear {
            permissionsCenter.refreshStatuses()
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
