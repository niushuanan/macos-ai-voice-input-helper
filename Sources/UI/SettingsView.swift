import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject private var permissionsCenter: PermissionsCenter

    init(model: AppModel) {
        self.model = model
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
    }

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

                GroupBox("Hotkey configuration") {
                    VStack(alignment: .leading, spacing: 10) {
                        KeyboardShortcuts.Recorder("Wake / Start", name: .wakeSession)
                        KeyboardShortcuts.Recorder("Stop / Submit", name: .stopSession)
                        KeyboardShortcuts.Recorder("Cancel Session", name: .cancelSession)

                        if let shortcutConflictWarning {
                            Label(shortcutConflictWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label("No shortcut conflict detected.", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        HStack {
                            Button("Reset to defaults") {
                                KeyboardShortcuts.reset(.wakeSession, .stopSession, .cancelSession)
                            }

                            Spacer()

                            Text("Global shortcuts are active immediately.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Permissions center") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(permissionsCenter.presentationItems()) { item in
                            PermissionRowView(
                                item: item,
                                onRequest: { permissionsCenter.requestAccess(for: item.id) },
                                onOpenSettings: { permissionsCenter.openSystemSettings(for: item.id) }
                            )
                        }

                        if permissionsCenter.snapshot.hasBlockingIssue {
                            Label("Voice session start is currently blocked by missing permission.", systemImage: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Label("Permission baseline is ready for starting voice sessions.", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        Button("Refresh permission status") {
                            permissionsCenter.refreshStatuses()
                        }
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
        .onAppear {
            permissionsCenter.refreshStatuses()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            permissionsCenter.refreshStatuses()
        }
    }

    private var shortcutConflictWarning: String? {
        let wake = KeyboardShortcuts.getShortcut(for: .wakeSession)
        let stop = KeyboardShortcuts.getShortcut(for: .stopSession)
        let cancel = KeyboardShortcuts.getShortcut(for: .cancelSession)

        if wake != nil && wake == stop {
            return "Wake and stop use the same shortcut. This can cause accidental phase jumps."
        }

        if wake != nil && wake == cancel {
            return "Wake and cancel use the same shortcut. Session control is ambiguous."
        }

        if stop != nil && stop == cancel {
            return "Stop and cancel use the same shortcut. Keep them separate for safer control."
        }

        return nil
    }
}

private struct PermissionRowView: View {
    let item: PermissionPresentation
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(item.title, systemImage: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateColor)

                Spacer()

                Text(item.state.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stateColor)
            }

            Text(item.detail)
                .font(.caption)

            Text(item.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if item.state != .granted && item.state != .notRequired {
                    Button("Request") {
                        onRequest()
                    }
                }

                Button("Open System Settings") {
                    onOpenSettings()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stateColor.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var iconName: String {
        switch item.state {
        case .granted, .notRequired:
            return "checkmark.circle.fill"
        case .pending:
            return "clock.fill"
        case .denied:
            return "exclamationmark.triangle.fill"
        case .notRequested:
            return "circle.dashed"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .granted, .notRequired:
            return .green
        case .pending:
            return .orange
        case .denied:
            return .red
        case .notRequested:
            return .secondary
        }
    }
}
