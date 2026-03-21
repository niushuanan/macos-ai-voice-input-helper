import KeyboardShortcuts
import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @ObservedObject private var controlCenterState: ControlCenterState
    @ObservedObject private var sessionStore: SessionStore
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore

    @State private var asrTesting = false
    @State private var textTesting = false
    @State private var asrTestResult: ConnectionTestResult?
    @State private var textTestResult: ConnectionTestResult?
    @State private var memoryFeedback: String?

    init(model: AppModel) {
        self.model = model
        _controlCenterState = ObservedObject(wrappedValue: model.controlCenterState)
        _sessionStore = ObservedObject(wrappedValue: model.sessionStore)
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _localHistoryStore = ObservedObject(wrappedValue: model.localHistoryStore)
    }

    var body: some View {
        NavigationSplitView {
            List(DesktopSection.allCases, selection: $controlCenterState.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationTitle("PulseType")
        } detail: {
            Group {
                switch controlCenterState.selectedSection {
                case .home:
                    homePage
                case .memory:
                    memoryPage
                case .skills:
                    PlaceholderPageView(
                        title: "技能",
                        subtitle: "下一步会在这里提供可开关的技能中心。"
                    )
                case .model:
                    PlaceholderPageView(
                        title: "模型",
                        subtitle: "下一步会在这里固定展示 ASR 与文本处理两张模型卡片。"
                    )
                case .settings:
                    PlaceholderPageView(
                        title: "设置",
                        subtitle: "下一步会在这里展示热键、权限、场景策略与关于信息。"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Label("主键：\(wakeShortcutText)", systemImage: "keyboard")
                    Label("模式：\(sessionStore.activeLane.title)", systemImage: "slider.horizontal.3")
                    Label("阶段：\(sessionStore.phase.title)", systemImage: sessionStore.phase.menuBarSymbol)
                }
                .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    Text("开始语音")
                        .font(.title3.weight(.semibold))

                    Text(sessionStore.statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if permissionsCenter.snapshot.microphone != .granted {
                        Label("还没有麦克风权限，先在权限中心点“请求权限”。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    HStack {
                        Button(primaryToggleTitle) {
                            model.interactionCoordinator.handleWakeInput(context: .dictation)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canToggleSession)

                        Button("取消当前会话", role: .destructive) {
                            model.interactionCoordinator.handleCancelInput()
                        }
                        .buttonStyle(.bordered)
                        .disabled(sessionStore.phase == .idle)

                        Spacer()
                    }

                    if let latest = sessionStore.latestTranscription {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("最近结果")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(latest.transcript)
                                .lineLimit(4)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack(spacing: 12) {
                    HomeMetricCard(
                        title: "今日时长",
                        value: durationText(controlCenterState.homeStatsSnapshot.totalDurationSeconds),
                        subtitle: "来自本地历史"
                    )
                    HomeMetricCard(
                        title: "今日字数",
                        value: "\(controlCenterState.homeStatsSnapshot.totalCharacters)",
                        subtitle: "输出文本统计"
                    )
                    HomeMetricCard(
                        title: "当前速度",
                        value: speedText(controlCenterState.homeStatsSnapshot.charactersPerMinute),
                        subtitle: "字/分钟"
                    )
                }
            }
            .padding(20)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
        }
    }

    private var memoryPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("过滤", selection: $controlCenterState.memoryFilter) {
                    ForEach(LocalHistoryFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                Spacer()

                Button("清空记录", role: .destructive) {
                    localHistoryStore.clearAll()
                    memoryFeedback = "本地历史已清空。"
                }
                .buttonStyle(.bordered)
                .disabled(localHistoryStore.entries.isEmpty)
            }

            if let memoryFeedback {
                Text(memoryFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if filteredHistoryEntries.isEmpty {
                Spacer()
                Text("当前筛选下还没有记录。")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(filteredHistoryEntries) { entry in
                        MemoryRowView(
                            entry: entry,
                            onCopy: { copyHistoryEntry(entry) },
                            onDelete: {
                                localHistoryStore.delete(entryID: entry.id)
                                memoryFeedback = "已删除一条记录。"
                            }
                        )
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var legacyConsolePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerSection
            Form {
                sessionControlSection
                modelConfigurationSection
                permissionsSection
                diagnosticsSection
                sessionSnapshotSection
            }
        }
        .padding(20)
        .onAppear {
            permissionsCenter.refreshStatuses()
            providerSettingsStore.refreshCredentialState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            permissionsCenter.refreshStatuses()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PulseType 主界面")
                .font(.title.weight(.bold))
            Text("一个页面完成会话控制、模型配置、权限与诊断。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var sessionSnapshotSection: some View {
        Section("会话动态") {
            LabeledContent("阶段", value: sessionStore.phase.title)
            LabeledContent("模式", value: sessionStore.activeLane.title)
            LabeledContent("状态", value: sessionStore.statusMessage)

            if let latest = sessionStore.latestTranscription {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近转写")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(latest.transcript)
                        .font(.callout)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }

            if let output = sessionStore.latestOutputResult {
                LabeledContent(
                    "写回路径",
                    value: output.usedFallback ? "粘贴兜底" : "AX 直写"
                )
            }

            if let error = sessionStore.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var sessionControlSection: some View {
        Section("会话控制") {
            Label("当前阶段：\(sessionStore.phase.title)", systemImage: sessionStore.phase.menuBarSymbol)
                .font(.subheadline.weight(.semibold))

            Text(sessionStore.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            KeyboardShortcuts.Recorder("语音输入主快捷键（开始/停止）", name: .wakeSession)
            KeyboardShortcuts.Recorder("取消当前会话快捷键", name: .cancelSession)

            if let conflict = shortcutConflictWarning {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("快捷键冲突检查通过。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Button(primaryToggleTitle) {
                    model.interactionCoordinator.handleWakeInput(context: .dictation)
                }
                .disabled(!canToggleSession)

                Button("取消当前会话", role: .destructive) {
                    model.interactionCoordinator.handleCancelInput()
                }
                .disabled(sessionStore.phase == .idle)

                Spacer()

                Button("恢复默认快捷键") {
                    KeyboardShortcuts.reset(.wakeSession, .stopSession, .cancelSession)
                }
            }
            .buttonStyle(.bordered)

            Text("交互规则：主快捷键在空闲时开始录音，聆听中再次按下会停止并进入后续处理。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelConfigurationSection: some View {
        Section("模型配置") {
            ModelConfigCard(
                title: "语音识别（ASR）",
                providerType: asrProviderTypeBinding,
                baseURL: asrBaseURLBinding,
                modelName: asrModelBinding,
                allowsCustomBaseURL: providerSettingsStore.asrConfig.providerType.allowsCustomBaseURL,
                baseURLPlaceholder: providerSettingsStore.asrConfig.providerType.allowsCustomBaseURL
                    ? "https://your-openai-compatible.com"
                    : "https://api.openai.com（固定）",
                modelPlaceholder: "whisper-1",
                apiKeyDraft: $providerSettingsStore.asrAPIKeyDraft,
                credentialState: providerSettingsStore.asrCredentialState,
                validationMessage: providerSettingsStore.asrConfigurationValidationMessage,
                feedbackMessage: providerSettingsStore.asrFeedbackMessage,
                onSaveKey: { providerSettingsStore.saveASRAPIKeyDraft() },
                onDeleteKey: { providerSettingsStore.clearASRAPIKey() }
            )

            ModelConfigCard(
                title: "文本处理",
                providerType: textProviderTypeBinding,
                baseURL: textBaseURLBinding,
                modelName: textModelBinding,
                allowsCustomBaseURL: providerSettingsStore.textConfig.providerType.allowsCustomBaseURL,
                baseURLPlaceholder: providerSettingsStore.textConfig.providerType.allowsCustomBaseURL
                    ? "https://your-openai-compatible.com"
                    : "https://api.openai.com（固定）",
                modelPlaceholder: "gpt-4o-mini",
                apiKeyDraft: $providerSettingsStore.textAPIKeyDraft,
                credentialState: providerSettingsStore.textCredentialState,
                validationMessage: providerSettingsStore.textConfigurationValidationMessage,
                feedbackMessage: providerSettingsStore.textFeedbackMessage,
                onSaveKey: { providerSettingsStore.saveTextAPIKeyDraft() },
                onDeleteKey: { providerSettingsStore.clearTextAPIKey() }
            )

            Text("安全策略：密钥仅写入 macOS 钥匙串，不写入明文配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("权限中心") {
            ForEach(permissionsCenter.presentationItems()) { item in
                PermissionRowView(
                    item: item,
                    onRequest: { permissionsCenter.requestAccess(for: item.id) },
                    onOpenSettings: { permissionsCenter.openSystemSettings(for: item.id) }
                )
            }

            if permissionsCenter.snapshot.microphone != .granted {
                Label("缺少麦克风权限，无法开始录音。", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Label("麦克风权限已就绪。", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if permissionsCenter.snapshot.accessibility != .granted {
                Label("辅助功能未允许：选区改写不可用；普通听写可继续，但写回成功率会下降。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("辅助功能权限已就绪。", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button("重新检测权限") {
                permissionsCenter.refreshStatuses()
            }
            .buttonStyle(.bordered)
        }
    }

    private var diagnosticsSection: some View {
        Section("诊断与测试") {
            Text("可点击按钮发起真实请求，验证接口地址、模型名、密钥与额度。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(asrTesting ? "测试ASR中..." : "测试ASR") {
                    runASRTest()
                }
                .disabled(asrTesting)

                Button(textTesting ? "测试文本模型中..." : "测试文本模型") {
                    runTextTest()
                }
                .disabled(textTesting)
            }
            .buttonStyle(.bordered)

            if let latestResult {
                ConnectionTestSummaryView(title: "最近一次测试结果", result: latestResult)
            } else {
                Text("还没有测试记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let asrTestResult {
                ConnectionTestSummaryView(title: "ASR 最近结果", result: asrTestResult)
            }

            if let textTestResult {
                ConnectionTestSummaryView(title: "文本模型最近结果", result: textTestResult)
            }
        }
    }

    private var asrProviderTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.asrConfig.providerType },
            set: { providerSettingsStore.updateASRProviderType($0) }
        )
    }

    private var textProviderTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.textConfig.providerType },
            set: { providerSettingsStore.updateTextProviderType($0) }
        )
    }

    private var asrBaseURLBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.asrConfig.baseURLString },
            set: { providerSettingsStore.updateASRBaseURL($0) }
        )
    }

    private var textBaseURLBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.textConfig.baseURLString },
            set: { providerSettingsStore.updateTextBaseURL($0) }
        )
    }

    private var asrModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.asrConfig.modelName },
            set: { providerSettingsStore.updateASRModel($0) }
        )
    }

    private var textModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.textConfig.modelName },
            set: { providerSettingsStore.updateTextModel($0) }
        )
    }

    private var shortcutConflictWarning: String? {
        let wake = KeyboardShortcuts.getShortcut(for: .wakeSession)
        let cancel = KeyboardShortcuts.getShortcut(for: .cancelSession)
        if wake != nil && wake == cancel {
            return "主快捷键与取消键重复，会导致会话行为不明确。"
        }
        return nil
    }

    private var canToggleSession: Bool {
        switch sessionStore.phase {
        case .idle, .cancelled, .error:
            return true
        case .listening:
            return true
        case .transcribing, .rewriting, .inserting:
            return false
        }
    }

    private var primaryToggleTitle: String {
        sessionStore.phase == .listening ? "停止并处理" : "开始语音输入"
    }

    private var latestResult: ConnectionTestResult? {
        switch (asrTestResult, textTestResult) {
        case let (.some(asr), .some(text)):
            return asr.timestamp >= text.timestamp ? asr : text
        case let (.some(asr), .none):
            return asr
        case let (.none, .some(text)):
            return text
        case (.none, .none):
            return nil
        }
    }

    private var filteredHistoryEntries: [SessionHistoryEntry] {
        localHistoryStore.entries(matching: controlCenterState.memoryFilter)
    }

    private var wakeShortcutText: String {
        KeyboardShortcuts.getShortcut(for: .wakeSession)?
            .description
            .replacingOccurrences(of: "-", with: " + ")
            ?? "Control + Option + Space"
    }

    private func durationText(_ seconds: Double) -> String {
        let safeSeconds = max(0, Int(seconds.rounded()))
        let minutes = safeSeconds / 60
        let remainSeconds = safeSeconds % 60
        return "\(minutes)分 \(remainSeconds)秒"
    }

    private func speedText(_ value: Double) -> String {
        let safe = max(0, Int(value.rounded()))
        return "\(safe)"
    }

    private func copyHistoryEntry(_ entry: SessionHistoryEntry) {
        let text = (entry.outputText ?? entry.inputText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            memoryFeedback = "这条记录没有可复制的文本。"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        memoryFeedback = "已复制文本。"
    }

    private func runASRTest() {
        guard !asrTesting else {
            return
        }
        asrTesting = true
        Task {
            let result = await providerSettingsStore.testASRConnection()
            await MainActor.run {
                asrTestResult = result
                asrTesting = false
            }
        }
    }

    private func runTextTest() {
        guard !textTesting else {
            return
        }
        textTesting = true
        Task {
            let result = await providerSettingsStore.testTextConnection()
            await MainActor.run {
                textTestResult = result
                textTesting = false
            }
        }
    }
}

private struct PlaceholderPageView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MemoryRowView: View {
    let entry: SessionHistoryEntry
    let onCopy: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label(modeTitle, systemImage: modeSymbol)
                    .font(.caption)
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Text(textPreview)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)

            HStack {
                Text(entry.appName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制") {
                    onCopy()
                }
                .buttonStyle(.bordered)

                Button("删除", role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var modeTitle: String {
        switch entry.mode {
        case .dictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
        }
    }

    private var modeSymbol: String {
        switch entry.mode {
        case .dictation:
            return "mic"
        case .selectionRewrite:
            return "wand.and.stars"
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

    private var textPreview: String {
        let output = (entry.outputText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            return output
        }
        let input = entry.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.isEmpty {
            return input
        }
        if let error = entry.errorMessage, !error.isEmpty {
            return error
        }
        return "无文本内容"
    }
}

private struct HomeMetricCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ModelConfigCard: View {
    let title: String
    let providerType: Binding<ProviderType>
    let baseURL: Binding<String>
    let modelName: Binding<String>
    let allowsCustomBaseURL: Bool
    let baseURLPlaceholder: String
    let modelPlaceholder: String
    @Binding var apiKeyDraft: String
    let credentialState: ProviderSettingsStore.CredentialState
    let validationMessage: String?
    let feedbackMessage: String?
    let onSaveKey: () -> Bool
    let onDeleteKey: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.top, 2)

            Picker("Provider 类型", selection: providerType) {
                ForEach(ProviderType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)

            Text("API 地址")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(baseURLPlaceholder, text: baseURL)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(!allowsCustomBaseURL)

            Text("模型名")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(modelPlaceholder, text: modelName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            Text("API 密钥")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SecureField("请输入 API 密钥", text: $apiKeyDraft)
                    .textFieldStyle(.roundedBorder)

                Button("保存") {
                    _ = onSaveKey()
                }
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("删除", role: .destructive) {
                    _ = onDeleteKey()
                }
                .disabled(credentialState == .missing)
            }
            .buttonStyle(.bordered)

            Label(
                credentialState == .saved ? "密钥已保存（钥匙串）" : "密钥未保存",
                systemImage: credentialState == .saved ? "lock.shield.fill" : "exclamationmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let feedbackMessage {
                Text(feedbackMessage)
                    .font(.caption)
                    .foregroundStyle(feedbackMessage.contains("无法") || feedbackMessage.contains("失败") ? .red : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

private struct ConnectionTestSummaryView: View {
    let title: String
    let result: ConnectionTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(statusTitle, systemImage: statusIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            Text(result.message)
                .font(.caption)
                .textSelection(.enabled)

            Text(result.hint)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(metaLine)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var statusTitle: String {
        result.status == .success ? "成功" : "失败"
    }

    private var statusIcon: String {
        result.status == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
    }

    private var statusColor: Color {
        result.status == .success ? .green : .red
    }

    private var metaLine: String {
        let time = result.timestamp.formatted(date: .omitted, time: .standard)
        if let httpStatus = result.httpStatus {
            return "HTTP \(httpStatus) · \(time)"
        }
        return "HTTP - · \(time)"
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

                Text(stateText)
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
                    Button("请求权限") {
                        onRequest()
                    }
                }

                Button("打开系统设置") {
                    onOpenSettings()
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
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
            return .green
        case .pending:
            return .orange
        case .denied:
            return .red
        case .notRequested:
            return .secondary
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
}
