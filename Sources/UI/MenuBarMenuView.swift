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
        Text("当前状态：\(model.sessionStore.phase.title)")
            .font(.caption)
        Text(model.sessionStore.phase == .listening ? "正在聆听你的输入" : "点击下面按钮开始语音输入")
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

        Menu("开发者信息") {
            Text("通道：\(model.sessionStore.activeLane.title)")
            Text("语音引擎：\(providerSettingsStore.selectedTranscriptionProviderName)")
            Text("文本引擎：\(providerSettingsStore.selectedRewriteProviderName)")
            Text("主键：\(hotkeyStateStore.wakeShortcutText)")
            Text("取消键：\(hotkeyStateStore.cancelShortcutText)")
            Text("讨论整理触发：\(hotkeyStateStore.brainstormShortcutText)")
        }

        Divider()

        Button(primaryToggleTitle) {
            model.interactionCoordinator.handleWakeInput(context: .dictation)
        }
        .disabled(!canToggleSession)
        .globalKeyboardShortcut(.wakeSession)

        Button(brainstormToggleTitle) {
            model.interactionCoordinator.handleBrainstormInput()
        }
        .disabled(!canToggleBrainstormSession)
        .globalKeyboardShortcut(.brainstormSession)

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

    private var canToggleBrainstormSession: Bool {
        switch model.sessionStore.phase {
        case .idle, .cancelled, .error:
            return true
        case .listening:
            return model.sessionStore.activeLane == .brainstormDiscussion
        case .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private var primaryToggleTitle: String {
        if model.sessionStore.phase == .listening {
            return "停止并处理"
        }
        return "开始听写"
    }

    private var brainstormToggleTitle: String {
        if model.sessionStore.phase == .listening, model.sessionStore.activeLane == .brainstormDiscussion {
            return "停止并整理一口气全念对"
        }
        return "开始一口气全念对"
    }
}
