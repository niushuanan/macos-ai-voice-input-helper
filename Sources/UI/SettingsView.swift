import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PulseType")
                        .font(.largeTitle.weight(.bold))

                    Text("A keyboard-first macOS helper app for dictation and selection rewrite.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Product posture") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Helper app, not an InputMethodKit extension.")
                        Text("Cloud model APIs come first, with user-supplied keys in the app UI.")
                        Text("History, sessions, and configuration stay local by default.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Planned hotkeys") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(model.hotkeyCoordinator.wakeShortcut.name): \(model.hotkeyCoordinator.wakeShortcut.trigger)")
                        Text("\(model.hotkeyCoordinator.stopShortcut.name): \(model.hotkeyCoordinator.stopShortcut.trigger)")
                        Text("\(model.hotkeyCoordinator.cancelShortcut.name): \(model.hotkeyCoordinator.cancelShortcut.trigger)")
                        Text("\(model.hotkeyCoordinator.rewriteModifierHint.name): \(model.hotkeyCoordinator.rewriteModifierHint.trigger)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Permission roadmap") {
                    let permissions = model.permissionsCenter.currentSnapshot()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Microphone: \(permissions.microphone.rawValue)")
                        Text("Accessibility: \(permissions.accessibility.rawValue)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Local data paths") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.localStore.rootDirectory.path)
                        Text(model.localStore.historyDirectory.path)
                        Text(model.localStore.diagnosticsDirectory.path)
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.diagnosticsCenter.summaryLines(), id: \.self) { line in
                            Text(line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
