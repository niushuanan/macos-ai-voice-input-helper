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

        Button("开始听写") {
            model.interactionCoordinator.handleWakeInput(context: .dictation)
        }
        .disabled(!canStartSession)
        .globalKeyboardShortcut(.wakeSession)

        Button("开始改写") {
            model.interactionCoordinator.handleWakeInput(
                context: WakeInvocationContext(
                    rewriteModifierHeld: true,
                    selectionAvailable: true
                )
            )
        }
        .disabled(!canStartSession)

        Button("停止") {
            model.interactionCoordinator.handleStopInput()
        }
        .disabled(model.sessionStore.phase != .listening)
        .globalKeyboardShortcut(.stopSession)

        Button("取消会话") {
            model.interactionCoordinator.handleCancelInput()
        }
        .disabled(model.sessionStore.phase == .idle)
        .globalKeyboardShortcut(.cancelSession)

        Divider()

        Button("打开命令台") {
            openWindow(id: "command-deck")
        }

        SettingsLink {
            Text("设置")
        }

        Button("退出 PulseType") {
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
