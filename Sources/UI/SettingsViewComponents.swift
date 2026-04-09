import AppKit
import SwiftUI

struct PlaceholderPageView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.primary.opacity(0.84))
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct MemoryRowView: View {
    let entry: SessionHistoryEntry
    let onCopyPrimary: () -> Void
    let onCopyDialogue: () -> Void
    let onCopyRaw: () -> Void
    let onCopyCommand: () -> Void
    let onCopyExecutionInterpretation: () -> Void
    let onCopyExecutionTrace: () -> Void
    let onDelete: () -> Void
    @State private var brainstormDetailsExpanded = false
    @State private var magicianTraceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                if let outputPathTitle {
                    Label(outputPathTitle, systemImage: outputPathSymbol)
                        .font(.caption2)
                        .foregroundStyle(outputPathColor)
                }
            }

            if entry.mode == .dictation {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(primaryText ?? "暂无主文本")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        Menu {
                            Button("复制主文本") {
                                onCopyPrimary()
                            }
                            .disabled(primaryText == nil)

                            Button("复制原始文本") {
                                onCopyRaw()
                            }
                            .disabled(rawText == nil)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .help("复制文本")
                    }

                    if let rawText {
                        Text("(\(rawText))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            } else if entry.mode == .brainstorm {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(brainstormSummaryText ?? "暂无结论")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        Menu {
                            Button("复制结论") {
                                onCopyPrimary()
                            }
                            .disabled(brainstormSummaryText == nil)

                            Button("复制对话") {
                                onCopyDialogue()
                            }
                            .disabled(brainstormDialogueText == nil)

                            Button("复制原始记录") {
                                onCopyRaw()
                            }
                            .disabled(brainstormRawText == nil)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .help("复制文本")
                    }

                    if brainstormDetailsExpanded {
                        if let brainstormDialogueText {
                            Text(brainstormDialogueText)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }

                        if let brainstormRawText {
                            Text(brainstormRawText)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else if entry.mode == .selectionRewrite {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        Text(magicianPrimaryText ?? "暂无结果")
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        Menu {
                            Button("复制结果") {
                                onCopyPrimary()
                            }
                            .disabled(magicianPrimaryText == nil)

                            Button("复制原文") {
                                onCopyRaw()
                            }
                            .disabled(magicianSecondaryText == nil)

                            Button("复制命令") {
                                onCopyCommand()
                            }
                            .disabled(magicianInstructionText == nil)

                            Button("复制执行解读") {
                                onCopyExecutionInterpretation()
                            }
                            .disabled(magicianExecutionInterpretation == nil)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                        .menuStyle(.borderlessButton)
                        .help("复制文本")
                    }

                    if let magicianSecondaryText {
                        Text(magicianSecondaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    if let magicianInstructionText {
                        Text(magicianInstructionText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    if let magicianExecutionInterpretation {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("执行解读")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(magicianExecutionInterpretation)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }

                    if magicianTraceExpanded, let magicianExecutionTrace {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("原始执行链路")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(magicianExecutionTrace)
                                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                        )
                    }
                }
            } else {
                Text(singleTextPreview)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if !entry.appliedSkills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entry.appliedSkills, id: \.rawValue) { skill in
                            Text(skill.title)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            HStack {
                Text(entry.appName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()

                if entry.mode == .brainstorm {
                    Button(brainstormDetailsExpanded ? "隐藏详情" : "展开详情") {
                        brainstormDetailsExpanded.toggle()
                    }
                    .controlCenterSecondaryActionButton()
                    .disabled(!hasBrainstormDetails)
                } else if entry.mode == .selectionRewrite {
                    Button(magicianTraceExpanded ? "隐藏执行链路" : "展开执行链路") {
                        magicianTraceExpanded.toggle()
                    }
                    .controlCenterSecondaryActionButton()
                    .disabled(!hasMagicianTrace)

                    Button("复制执行链路") {
                        onCopyExecutionTrace()
                    }
                    .controlCenterSecondaryActionButton()
                    .disabled(!hasMagicianTrace)
                }

                Button("删除", role: .destructive) {
                    onDelete()
                }
                .controlCenterSecondaryActionButton()
            }
        }
    }

    private var statusTitle: String {
        switch entry.status {
        case .success:
            return "成功"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private var statusSymbol: String {
        switch entry.status {
        case .success:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .cancelled:
            return "slash.circle.fill"
        }
    }

    private var statusColor: Color {
        switch entry.status {
        case .success:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    private var primaryText: String? {
        MemoryEntryTextResolver.primaryText(for: entry)
    }

    private var rawText: String? {
        MemoryEntryTextResolver.rawText(for: entry)
    }

    private var brainstormSummaryText: String? {
        MemoryEntryTextResolver.brainstormSummaryText(for: entry)
    }

    private var brainstormDialogueText: String? {
        MemoryEntryTextResolver.brainstormDialogueText(for: entry)
    }

    private var brainstormRawText: String? {
        MemoryEntryTextResolver.brainstormRawText(for: entry)
    }

    private var hasBrainstormDetails: Bool {
        brainstormDialogueText != nil || brainstormRawText != nil
    }

    private var magicianPrimaryText: String? {
        MemoryEntryTextResolver.magicianPrimaryText(for: entry)
    }

    private var magicianSecondaryText: String? {
        MemoryEntryTextResolver.magicianSecondaryText(for: entry)
    }

    private var magicianInstructionText: String? {
        MemoryEntryTextResolver.magicianInstructionText(for: entry)
    }

    private var magicianExecutionInterpretation: String? {
        MemoryEntryTextResolver.magicianExecutionInterpretation(for: entry)
    }

    private var magicianExecutionTrace: String? {
        let value = entry.magicianExecutionTrace?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            return value
        }
        return nil
    }

    private var hasMagicianTrace: Bool {
        magicianExecutionTrace != nil
    }

    private var singleTextPreview: String {
        MemoryEntryTextResolver.placeholder(for: entry)
    }

    private var outputPathTitle: String? {
        guard entry.status == .success, let path = entry.outputPath else {
            return nil
        }
        switch path {
        case .accessibilitySelectionReplacement:
            return "已写入输入框"
        case .pasteFallbackCommandV:
            return "已粘贴写入"
        case .clipboardOnly:
            return "仅剪贴板"
        }
    }

    private var outputPathSymbol: String {
        guard let path = entry.outputPath else {
            return "questionmark.circle"
        }
        switch path {
        case .accessibilitySelectionReplacement:
            return "square.and.pencil"
        case .pasteFallbackCommandV:
            return "doc.on.clipboard"
        case .clipboardOnly:
            return "clipboard"
        }
    }

    private var outputPathColor: Color {
        guard let path = entry.outputPath else {
            return .secondary
        }
        switch path {
        case .accessibilitySelectionReplacement, .pasteFallbackCommandV:
            return .green
        case .clipboardOnly:
            return .orange
        }
    }
}

struct SkillRuleCardView: View {
    let ruleID: SkillRuleID
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    @Binding var parameter: String
    let parameterPlaceholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.primary.opacity(0.84))
                }
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle())
                    .scaleEffect(0.8)
                    .fixedSize()
            }

            if ruleID == .systemPrompt {
                TextEditor(text: $parameter)
                    .font(.system(size: 13))
                    .frame(minHeight: 84, maxHeight: 120)
                    .padding(6)
                    .controlCenterInsetPanel()
                    .disabled(!isEnabled)
            } else {
                TextField(parameterPlaceholder, text: $parameter)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct ScenePolicyRowView: View {
    let policy: AppScenePolicy
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(policy.appName)
                    .font(.subheadline.weight(.semibold))
                if isEditing {
                    ControlCenterStatusPill(
                        title: "编辑中",
                        systemImage: "pencil",
                        tint: .accentColor
                    )
                }
                Spacer()
                Button("编辑") {
                    onEdit()
                }
                .controlCenterSecondaryActionButton()
                Button("删除", role: .destructive) {
                    onDelete()
                }
                .controlCenterSecondaryActionButton()
            }

            Text(policy.bundleID)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            Text(promptPreview)
                .font(.body)
                .foregroundStyle(promptPreview == "还没有专属提示词。" ? .secondary : .primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                ControlCenterStatusPill(title: "应用提示词", systemImage: "text.bubble", tint: .secondary)
                ControlCenterStatusPill(title: "普通听写/改写", systemImage: "wand.and.stars", tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var promptPreview: String {
        let value = policy.appPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "还没有专属提示词。"
        }
        return value
    }
}

struct SceneAppCandidateRowView: View {
    let app: SceneAppOption
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(app.appName)
                    .font(.subheadline.weight(.semibold))
                Text(app.bundleID)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("添加") {
                onAdd()
            }
            .controlCenterSecondaryActionButton()
        }
        .padding(8)
        .controlCenterInsetPanel(cornerRadius: 10)
    }
}

struct HomeMetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(PulseUI.Typography.captionStrong)
                .pulseTertiaryText()
            Text(value)
                .font(PulseUI.Typography.value)
                .pulsePrimaryText()
            Text(subtitle)
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PulseUI.Spacing.cardPadding)
        .pulseCard(cornerRadius: PulseUI.Radius.card)
    }
}

struct PulseToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(PulseUI.ColorTokens.success)
            Text(text)
                .font(PulseUI.Typography.bodyStrong)
                .pulsePrimaryText()
                .lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.75), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

struct ModelConfigCard: View {
    let title: String?
    let availableProviderTypes: [ProviderType]
    let providerType: Binding<ProviderType>
    let baseURL: Binding<String>
    let modelName: Binding<String>
    let localModelPath: Binding<String>?
    let showsBaseURL: Bool
    let showsAPIKey: Bool
    let allowsCustomBaseURL: Bool
    let baseURLPlaceholder: String
    let modelPlaceholder: String
    @Binding var apiKeyDraft: String
    let credentialState: ProviderSettingsStore.CredentialState
    let validationMessage: String?
    let feedbackMessage: String?
    let onSaveKey: () -> Void
    let onDeleteKey: () -> Void
    @State private var developerOptionsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(PulseUI.Typography.sectionTitle)
                    .pulseSecondaryText()
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("当前连接")
                    .font(PulseUI.Typography.captionStrong)
                    .pulseTertiaryText()
                HStack(spacing: 8) {
                    ControlCenterStatusPill(
                        title: providerType.wrappedValue.displayName,
                        systemImage: providerType.wrappedValue == .localSenseVoice ? "internaldrive.fill" : "cloud.fill",
                        tint: providerType.wrappedValue == .localSenseVoice ? PulseUI.ColorTokens.warning : .accentColor
                    )
                    Text(modelName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "模型名未填写" : modelName.wrappedValue)
                        .font(PulseUI.Typography.caption)
                        .pulseSecondaryText()
                        .lineLimit(1)
                }
            }

            DisclosureGroup("开发者选项", isExpanded: $developerOptionsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("连接方式", selection: providerType) {
                        ForEach(availableProviderTypes) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.regular)

                    if showsBaseURL {
                        Text("API 地址")
                            .font(PulseUI.Typography.captionStrong)
                            .pulseSecondaryText()
                        TextField(baseURLPlaceholder, text: baseURL)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .disabled(!allowsCustomBaseURL)
                    } else {
                        Label("本地模式不需要 API 地址。", systemImage: "internaldrive")
                            .font(PulseUI.Typography.caption)
                            .pulseSecondaryText()
                    }

                    Text("模型名")
                        .font(PulseUI.Typography.captionStrong)
                        .pulseSecondaryText()
                    TextField(modelPlaceholder, text: modelName)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    if let localModelPath {
                        Text("本地模型目录")
                            .font(PulseUI.Typography.captionStrong)
                            .pulseSecondaryText()
                        TextField(defaultSenseVoiceModelPath, text: localModelPath)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }

                    if showsAPIKey {
                        Text("API 密钥")
                            .font(PulseUI.Typography.captionStrong)
                            .pulseSecondaryText()
                        HStack {
                            SecureField("请输入 API 密钥", text: $apiKeyDraft)
                                .textFieldStyle(.roundedBorder)

                            Button("保存") {
                                onSaveKey()
                            }
                            .disabled(
                                apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || credentialState == .saving
                            )

                            Button("删除", role: .destructive) {
                                onDeleteKey()
                            }
                            .disabled(isDeleteDisabled)
                        }
                        .controlCenterSecondaryActionButton()
                        .controlSize(.small)

                        Label(
                            credentialStateTitle,
                            systemImage: credentialStateIcon
                        )
                        .font(PulseUI.Typography.caption)
                        .foregroundStyle(credentialStateColor)
                    } else {
                        Label("本地模型模式不需要 API 密钥。", systemImage: "lock.open.fill")
                            .font(PulseUI.Typography.caption)
                            .pulseSecondaryText()
                    }
                }
                .padding(.top, 8)
            }
            .font(PulseUI.Typography.bodyStrong)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(PulseUI.ColorTokens.danger)
            }

            if let feedbackMessage {
                Text(feedbackMessage)
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(
                        feedbackMessage.contains("无法") || feedbackMessage.contains("失败")
                            ? PulseUI.ColorTokens.danger
                            : PulseUI.ColorTokens.textSecondary
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private var credentialStateTitle: String {
        switch credentialState {
        case .saving:
            return "正在保存密钥…"
        case .saved:
            return "密钥已保存（本地）"
        case .inaccessible:
            return "当前密钥文件不能直接访问"
        case let .failed(status):
            if let status {
                return "密钥状态异常（OSStatus \(status)）"
            }
            return "密钥状态异常"
        case .unknown:
            return "密钥状态未检测"
        case .missing:
            return "密钥未保存"
        }
    }

    private var credentialStateIcon: String {
        switch credentialState {
        case .saving:
            return "arrow.triangle.2.circlepath"
        case .saved:
            return "lock.shield.fill"
        case .inaccessible:
            return "lock.trianglebadge.exclamationmark.fill"
        case .failed:
            return "xmark.shield.fill"
        case .unknown:
            return "questionmark.shield.fill"
        case .missing:
            return "exclamationmark.shield.fill"
        }
    }

    private var credentialStateColor: Color {
        switch credentialState {
        case .saving:
            return PulseUI.ColorTokens.textSecondary
        case .saved:
            return PulseUI.ColorTokens.textSecondary
        case .inaccessible:
            return PulseUI.ColorTokens.warning
        case .failed:
            return PulseUI.ColorTokens.danger
        case .unknown:
            return PulseUI.ColorTokens.textSecondary
        case .missing:
            return PulseUI.ColorTokens.textSecondary
        }
    }

    private var isDeleteDisabled: Bool {
        switch credentialState {
        case .missing, .unknown, .saving:
            return true
        case .saved, .inaccessible, .failed:
            return false
        }
    }
}

struct ModelStatusPanel: View {
    let activeConfigLine: String
    let latestResult: ConnectionTestResult?
    let isTesting: Bool
    let failureSuggestion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("状态")
                    .font(PulseUI.Typography.sectionTitle)
                    .pulsePrimaryText()
                Spacer()
                ControlCenterStatusPill(
                    title: statusTitle,
                    systemImage: statusIcon,
                    tint: statusColor
                )
            }

            Text(activeConfigLine)
                .font(PulseUI.Typography.body)
                .pulsePrimaryText()
                .lineLimit(2)
                .textSelection(.enabled)

            if let latestResult {
                Text(latestResult.message)
                    .font(PulseUI.Typography.body)
                    .pulsePrimaryText()
                    .textSelection(.enabled)

                if latestResult.status == .failure, let failureSuggestion {
                    Text(failureSuggestion)
                        .font(PulseUI.Typography.caption)
                        .pulseSecondaryText()
                }
            } else {
                Text("还没有测试记录。")
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
            }
        }
        .padding(PulseUI.Spacing.compactCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterInsetPanel(cornerRadius: PulseUI.Radius.compactCard)
    }

    private var statusTitle: String {
        if isTesting {
            return "测试中"
        }
        guard let latestResult else {
            return "未测试"
        }
        return latestResult.status == .success ? "成功" : "失败"
    }

    private var statusIcon: String {
        if isTesting {
            return "hourglass"
        }
        guard let latestResult else {
            return "clock"
        }
        return latestResult.status == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private var statusColor: Color {
        if isTesting {
            return .accentColor
        }
        guard let latestResult else {
            return PulseUI.ColorTokens.textSecondary
        }
        return latestResult.status == .success ? PulseUI.ColorTokens.success : PulseUI.ColorTokens.warning
    }
}

struct ConnectionTestSummaryView: View {
    let title: String
    let result: ConnectionTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(PulseUI.Typography.sectionTitle)
                    .pulsePrimaryText()
                Spacer()
                Label(statusTitle, systemImage: statusIcon)
                    .font(PulseUI.Typography.captionStrong)
                    .foregroundStyle(statusColor)
            }

            Text(result.message)
                .font(PulseUI.Typography.body)
                .pulsePrimaryText()
                .textSelection(.enabled)

            Text(result.hint)
                .font(PulseUI.Typography.caption)
                .pulseSecondaryText()

            Text(metaLine)
                .font(PulseUI.Typography.monospacedMeta)
                .pulseSecondaryText()
                .textSelection(.enabled)
        }
        .padding(PulseUI.Spacing.compactCardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlCenterInsetPanel(cornerRadius: 8)
    }

    private var statusTitle: String {
        result.status == .success ? "成功" : "失败"
    }

    private var statusIcon: String {
        result.status == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private var statusColor: Color {
        result.status == .success ? PulseUI.ColorTokens.success : PulseUI.ColorTokens.danger
    }

    private var metaLine: String {
        let time = result.timestamp.formatted(date: .omitted, time: .standard)
        if let httpStatus = result.httpStatus {
            return "HTTP \(httpStatus) · \(time)"
        }
        return "HTTP - · \(time)"
    }
}

struct PermissionRowView: View {
    let item: PermissionPresentation
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.12))
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Text(item.title)
                        .font(PulseUI.Typography.sectionTitle)
                        .pulsePrimaryText()

                    Spacer(minLength: 8)

                    ControlCenterStatusPill(
                        title: stateText,
                        systemImage: iconName,
                        tint: stateColor
                    )
                }

                Text(item.detail)
                    .font(PulseUI.Typography.body)
                    .pulseSecondaryText()
                    .fixedSize(horizontal: false, vertical: true)

                if showsGuidance {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: guidanceIconName)
                            .font(PulseUI.Typography.captionStrong)
                            .pulseSecondaryText()
                            .padding(.top, 1)

                        Text(item.guidance)
                            .font(PulseUI.Typography.caption)
                            .pulseSecondaryText()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if showsRequestButtons {
                    HStack(spacing: 8) {
                        Button("请求权限") {
                            onRequest()
                        }

                        Button("打开系统设置") {
                            onOpenSettings()
                        }
                    }
                    .controlCenterSecondaryActionButton()
                    .controlSize(.small)
                } else {
                    Button(secondaryActionTitle) {
                        onOpenSettings()
                    }
                    .buttonStyle(.plain)
                    .font(PulseUI.Typography.caption)
                    .pulseSecondaryText()
                }
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            return PulseUI.ColorTokens.success
        case .pending:
            return PulseUI.ColorTokens.warning
        case .denied:
            return PulseUI.ColorTokens.danger
        case .notRequested:
            return PulseUI.ColorTokens.textSecondary
        }
    }

    private var stateText: String {
        switch item.state {
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

    private var showsGuidance: Bool {
        item.state != .granted && item.state != .notRequired
    }

    private var showsRequestButtons: Bool {
        item.state == .notRequested || item.state == .denied
    }

    private var guidanceIconName: String {
        item.state == .pending ? "clock.badge.exclamationmark" : "info.circle"
    }

    private var secondaryActionTitle: String {
        item.state == .granted || item.state == .notRequired ? "查看系统设置" : "打开系统设置"
    }
}

struct MagicianPermissionSheetView: View {
    let prompt: MagicianPermissionPromptModel
    let onPrimary: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt.title)
                .font(.title3.weight(.semibold))
            Text(prompt.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(prompt.secondaryButtonTitle) {
                    onCancel()
                }
                .controlCenterSecondaryActionButton()

                Button(prompt.primaryButtonTitle) {
                    onPrimary()
                }
                .controlCenterPrimaryActionButton()
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

struct ControlCenterStatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(PulseUI.Typography.captionStrong)
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.14))
            )
            .foregroundStyle(tint)
    }
}
