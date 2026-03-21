import SwiftUI

struct DesktopDashboardView: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerCard
                quickActionCard
                statusCard
                providerCard
                permissionCard
            }
            .padding(24)
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.blue.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .navigationTitle("PulseType 控制台")
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("键盘优先的 AI 语音输入")
                .font(.system(size: 26, weight: .bold))

            Text("菜单栏常驻，桌面可视化控制。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Label("阶段：\(model.sessionStore.phase.title)", systemImage: model.sessionStore.phase.menuBarSymbol)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(model.sessionStore.phase.tintColor.opacity(0.15))
                    .clipShape(Capsule())

                Label("模式：\(model.sessionStore.activeLane.title)", systemImage: "square.stack.3d.up")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(model.sessionStore.activeLane.badgeColor.opacity(0.15))
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var quickActionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快速操作")
                .font(.headline)

            HStack(spacing: 10) {
                Button("开始听写") {
                    model.interactionCoordinator.handleWakeInput(context: .dictation)
                }
                .disabled(!canStartSession)

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

                Button("取消", role: .destructive) {
                    model.interactionCoordinator.handleCancelInput()
                }
                .disabled(model.sessionStore.phase == .idle)
            }

            HStack(spacing: 10) {
                Button("打开设置") {
                    openSettings()
                }

                Button("打开命令台") {
                    openWindow(id: "command-deck")
                }
            }

            Text("默认快捷键：开始 Ctrl+Opt+Space，停止 Ctrl+Opt+Return，取消 Ctrl+Opt+Escape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前会话状态")
                .font(.headline)

            Text(model.sessionStore.statusMessage)
                .font(.subheadline)

            if let transcription = model.sessionStore.latestTranscription {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近转写")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(transcription.transcript)
                        .font(.caption)
                        .lineLimit(3)
                }
            }

            if let outputResult = model.sessionStore.latestOutputResult {
                Text(outputResult.usedFallback ? "写回路径：粘贴兜底" : "写回路径：AX 直写")
                    .font(.caption)
                    .foregroundStyle(outputResult.usedFallback ? .orange : .green)
            }

            if let errorMessage = model.sessionStore.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var providerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("服务商")
                .font(.headline)

            Text("转写：\(model.providerSettingsStore.selectedTranscriptionProviderName)")
                .font(.subheadline)
            Text("改写：\(model.providerSettingsStore.selectedRewriteProviderName)")
                .font(.subheadline)
            Text("转写模型：\(model.providerSettingsStore.modelName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("改写模型：\(model.providerSettingsStore.rewriteModelName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("权限状态")
                .font(.headline)

            Text("麦克风：\(permissionStateText(model.permissionsCenter.snapshot.microphone))")
                .font(.subheadline)
            Text("辅助功能：\(permissionStateText(model.permissionsCenter.snapshot.accessibility))")
                .font(.subheadline)

            Button("刷新权限状态") {
                model.permissionsCenter.refreshStatuses()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var canStartSession: Bool {
        switch model.sessionStore.phase {
        case .idle, .cancelled, .error:
            return true
        case .listening, .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private func permissionStateText(_ state: PermissionState) -> String {
        switch state {
        case .notRequested:
            return "未请求"
        case .pending:
            return "请求中"
        case .granted:
            return "已允许"
        case .denied:
            return "已拒绝"
        case .notRequired:
            return "不需要"
        }
    }
}

private extension SessionPhase {
    var tintColor: Color {
        switch self {
        case .idle:
            return .secondary
        case .listening:
            return .blue
        case .transcribing:
            return .purple
        case .rewriting:
            return .orange
        case .inserting:
            return .green
        case .cancelled, .error:
            return .red
        }
    }
}

private extension InputLane {
    var badgeColor: Color {
        switch self {
        case .directDictation:
            return .blue
        case .selectionRewrite:
            return .orange
        }
    }
}
