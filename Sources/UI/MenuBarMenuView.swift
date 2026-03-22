import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuBarMenuView: View {
    let model: AppModel
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var hotkeyStateStore: HotkeyStateStore

    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _hotkeyStateStore = ObservedObject(wrappedValue: model.hotkeyStateStore)
    }

    var body: some View {
        Text("阶段：\(model.sessionStore.phase.title)")
            .font(.caption)
        Text("通道：\(model.sessionStore.activeLane.title)")
            .font(.caption)
        Text("转写：\(providerSettingsStore.selectedTranscriptionProviderName)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text("改写：\(providerSettingsStore.selectedRewriteProviderName)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text("主键：\(hotkeyStateStore.wakeShortcutText)")
            .font(.caption2)
            .foregroundStyle(.secondary)
        Text("取消键：\(hotkeyStateStore.cancelShortcutText)")
            .font(.caption2)
            .foregroundStyle(.secondary)

        if permissionsCenter.snapshot.hasBlockingIssue {
            Divider()

            Label("开始前需要麦克风权限。", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            Button("打开隐私设置") {
                permissionsCenter.openSystemSettings(for: .microphone)
            }
        }

        Divider()

        Button(primaryToggleTitle) {
            model.interactionCoordinator.handleWakeInput(context: .dictation)
        }
        .disabled(!canToggleSession)
        .globalKeyboardShortcut(.wakeSession)

        Button("开始改写") {
            model.interactionCoordinator.handleWakeInput(
                context: WakeInvocationContext(
                    rewriteModifierHeld: true,
                    selectionAvailable: true
                )
            )
        }
        .disabled(!canStartRewrite)

        Button("取消会话") {
            model.interactionCoordinator.handleCancelInput()
        }
        .disabled(model.sessionStore.phase == .idle)
        .globalKeyboardShortcut(.cancelSession)

        Divider()

        Button("打开主界面") {
            openWindow(id: "control-center")
        }

        Button("退出 PulseType") {
            NSApplication.shared.terminate(nil)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
            hotkeyStateStore.refresh()
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

    private var canToggleSession: Bool {
        switch model.sessionStore.phase {
        case .idle, .cancelled, .error:
            return true
        case .listening:
            return true
        case .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private var canStartRewrite: Bool {
        canStartSession && permissionsCenter.snapshot.accessibility == .granted
    }

    private var primaryToggleTitle: String {
        if model.sessionStore.phase == .listening {
            return "停止并处理"
        }
        return "开始听写"
    }
}
