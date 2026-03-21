import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusCard(sessionStore: model.sessionStore)

            interactionSkeletonSection

            laneSection

            quickFlowSection

            utilitySection
        }
        .padding(18)
        .frame(width: 360)
    }

    private var interactionSkeletonSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("快捷键骨架")
                .font(.headline)

            Text("唤醒：Control + Option + Space")
                .font(.caption)
            Text("停止：聆听中按 Control + Option + Return")
                .font(.caption)
            Text("取消：Control + Option + Escape")
                .font(.caption)
            Text("改写通道：先选中内容再唤醒")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var laneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("交互通道")
                .font(.headline)

            LaneCard(
                title: model.sessionStore.activeLane == .directDictation ? "普通听写（当前）" : "普通听写",
                subtitle: "把新文本写入当前焦点输入位置",
                shortcut: model.hotkeyCoordinator.wakeShortcut.trigger,
                accent: .blue
            )

            LaneCard(
                title: "选区改写",
                subtitle: "不离开键盘，对选中内容说指令改写",
                shortcut: model.hotkeyCoordinator.rewriteModifierHint.trigger,
                accent: .orange
            )
        }
    }

    private var quickFlowSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("会话流转演练")
                .font(.headline)

            HStack {
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
            }

            HStack {
                Button("改写阶段") {
                    model.sessionStore.markRewriting()
                }
                .disabled(model.sessionStore.phase != .transcribing)

                Button("写回阶段") {
                    model.sessionStore.markInserting()
                }
                .disabled(!canInsert)

                Button("完成") {
                    model.interactionCoordinator.handleCompleteInput()
                }
                .disabled(model.sessionStore.phase != .inserting)
            }

            HStack {
                Button("取消", role: .destructive) {
                    model.interactionCoordinator.handleCancelInput()
                }
                .disabled(model.sessionStore.phase == .idle)

                Button("模拟异常") {
                    model.sessionStore.fail(message: "服务商或权限异常，导致会话中断。")
                }

                Button("重置") {
                    model.interactionCoordinator.handleResetInput()
                }
            }
        }
    }

    private var utilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            Text("服务商与本地存储")
                .font(.headline)

            InfoRow(title: "转写服务商", value: model.providerSettingsStore.selectedTranscriptionProviderName)
            InfoRow(title: "改写服务商", value: model.providerSettingsStore.selectedRewriteProviderName)
            InfoRow(title: "转写模型", value: model.providerSettingsStore.modelName)
            InfoRow(title: "改写模型", value: model.providerSettingsStore.rewriteModelName)
            InfoRow(title: "写回路径", value: model.textOutputCoordinator.insertionStrategy)
            InfoRow(title: "场景输出风格", value: activeScenePolicy.outputBias.displayName)
            InfoRow(
                title: "场景通道建议",
                value: activeScenePolicy.preferSelectionRewrite
                    ? "有选区时优先改写"
                    : "优先普通听写"
            )
            InfoRow(title: "历史目录", value: model.localStore.rootDirectory.path)

            HStack {
                SettingsLink {
                    Label("打开设置", systemImage: "gearshape")
                }

                Spacer()

                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.top, 4)
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

    private var canInsert: Bool {
        model.sessionStore.phase == .rewriting || model.sessionStore.phase == .transcribing
    }

    private var activeScenePolicy: AppScenePolicy {
        let context = model.contextDetector.focusedAppContext()
        return model.appScenePolicyStore.policy(for: context)
    }
}

private struct StatusCard: View {
    @ObservedObject var sessionStore: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(sessionStore.phase.title, systemImage: sessionStore.phase.menuBarSymbol)
                    .font(.headline)
                    .foregroundStyle(sessionStore.phase.tintColor)

                Spacer()

                Text(sessionStore.activeLane.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(sessionStore.activeLane.badgeColor.opacity(0.16))
                    .clipShape(Capsule())
            }

            Text(sessionStore.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.primary)

            if sessionStore.phase == .listening {
                ListeningLevelStrip(level: sessionStore.listeningLevel)
            }

            if let clip = sessionStore.pendingClip {
                Text("待处理音频：\(clip.displaySummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if sessionStore.phase == .transcribing {
                Label("请求处理中，可保持此窗口开启以观察状态。", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let latestTranscription = sessionStore.latestTranscription {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近转写 · \(latestTranscription.providerName) · \(latestTranscription.modelName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(latestTranscription.transcript)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(5)
                }
            }

            if let focusContext = sessionStore.latestFocusContext {
                VStack(alignment: .leading, spacing: 4) {
                    Text("目标应用：\(focusContext.appName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text("应用标识：\(focusContext.bundleID)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Label(
                        focusContext.hasEditableTarget
                            ? "已检测到可编辑目标"
                            : "未检测到可编辑目标",
                        systemImage: focusContext.hasEditableTarget
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(focusContext.hasEditableTarget ? .green : .orange)

                    Text("策略提示：\(focusContext.strategyHint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }

            if let outputResult = sessionStore.latestOutputResult {
                Label(
                    outputResult.usedFallback
                        ? "写回路径：粘贴兜底（Command+V）"
                        : "写回路径：AX 直写",
                    systemImage: outputResult.usedFallback
                        ? "arrow.triangle.branch"
                        : "arrow.forward.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(outputResult.usedFallback ? .orange : .green)
            }

            if let errorMessage = sessionStore.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sessionStore.phase.tintColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ListeningLevelStrip: View {
    let level: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("输入音量")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.blue.opacity(0.15))

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.55), Color.blue],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(height: 8)
            .animation(.linear(duration: 0.06), value: level)
        }
    }
}

private struct LaneCard: View {
    let title: String
    let subtitle: String
    let shortcut: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(shortcut)
                .font(.caption.monospaced())
                .foregroundStyle(accent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.caption)
                .textSelection(.enabled)
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
        case .cancelled:
            return .red
        case .error:
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
