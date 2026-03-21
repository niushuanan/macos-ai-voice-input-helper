import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var appScenePolicyStore: AppScenePolicyStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore
    @State private var focusedAppContext: FocusedAppContext
    @State private var focusedAppOutputBias: AppOutputBias
    @State private var focusedAppPreferSelectionRewrite: Bool
    @State private var historyModeFilter: HistoryModeFilter = .all
    @State private var historyStatusFilter: HistoryStatusFilter = .all
    @State private var historyAppQuery: String = ""
    @State private var historyOnlyFocusedApp: Bool = false

    init(model: AppModel) {
        self.model = model
        let initialContext = model.contextDetector.focusedAppContext()
        let initialPolicy = model.appScenePolicyStore.policy(for: initialContext)
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _appScenePolicyStore = ObservedObject(wrappedValue: model.appScenePolicyStore)
        _localHistoryStore = ObservedObject(wrappedValue: model.localHistoryStore)
        _focusedAppContext = State(initialValue: initialContext)
        _focusedAppOutputBias = State(initialValue: initialPolicy.outputBias)
        _focusedAppPreferSelectionRewrite = State(initialValue: initialPolicy.preferSelectionRewrite)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PulseType")
                        .font(.largeTitle.weight(.bold))

                    Text("键盘优先的 macOS 语音输入助手，支持普通听写与选区改写。")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                GroupBox("产品定位") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("这是 Helper App，不是 InputMethodKit 输入法。")
                        Text("当前阶段优先接云端模型 API，用户在界面中填写自己的 Key。")
                        Text("历史、会话与配置默认保留在本地。")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("服务商中心") {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("角色分配")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Picker("转写服务商", selection: $providerSettingsStore.selectedTranscriptionProfileID) {
                                ForEach(providerSettingsStore.enabledProfiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)

                            Picker("改写服务商", selection: $providerSettingsStore.selectedRewriteProfileID) {
                                ForEach(providerSettingsStore.enabledProfiles) { profile in
                                    Text(profile.name).tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        if let validationMessage = providerSettingsStore.configurationValidationMessage {
                            Label("转写配置：\(validationMessage)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if let rewriteValidation = providerSettingsStore.rewriteConfigurationValidationMessage {
                            Label("改写配置：\(rewriteValidation)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("配置编辑")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Picker("编辑目标", selection: $providerSettingsStore.selectedProfileIDForEditing) {
                                ForEach(providerSettingsStore.profiles) { profile in
                                    Text("\(profile.name) · \(profile.type.shortLabel)")
                                        .tag(profile.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("配置名称")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("请输入配置名称", text: editingProfileNameBinding)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }

                        Picker("服务商类型", selection: editingProfileTypeBinding) {
                            ForEach(ProviderType.allCases) { type in
                                Text(type.displayName).tag(type)
                            }
                        }
                        .pickerStyle(.menu)

                        Toggle("启用此配置", isOn: editingProfileEnabledBinding)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("接口地址（Base URL）")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField(
                                editingProfileType == .openAI
                                    ? "https://api.openai.com（固定）"
                                    : "https://your-compatible-endpoint.com",
                                text: editingBaseURLBinding
                            )
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .disabled(!editingProfileType.allowsCustomBaseURL)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("转写模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("whisper-1", text: editingTranscriptionModelBinding)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("改写模型")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("gpt-4o-mini", text: editingRewriteModelBinding)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("API 密钥")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            HStack {
                                SecureField("请输入 \(editingProfileName) 的 API 密钥", text: $providerSettingsStore.apiKeyDraft)
                                    .textFieldStyle(.roundedBorder)

                                Button("保存") {
                                    providerSettingsStore.saveDraftedAPIKey()
                                }
                                .disabled(providerSettingsStore.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                Button("删除", role: .destructive) {
                                    providerSettingsStore.clearSavedAPIKey()
                                }
                                .disabled(providerSettingsStore.credentialState == .missing)
                            }
                        }

                        HStack {
                            Button("新增配置") {
                                providerSettingsStore.addProfile()
                            }

                            Button("删除配置", role: .destructive) {
                                providerSettingsStore.deleteEditingProfile()
                            }
                            .disabled(providerSettingsStore.profiles.count <= 1)
                        }

                        Label(apiKeyStatusText, systemImage: apiKeyStatusIcon)
                            .font(.caption)
                            .foregroundStyle(apiKeyStatusColor)

                        if let feedbackMessage = providerSettingsStore.feedbackMessage {
                            Text(feedbackMessage)
                                .font(.caption)
                                .foregroundStyle(feedbackColor)
                        }

                        Text("密钥存储策略：仅写入 macOS 钥匙串，不写明文配置文件。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("默认快捷键") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(model.hotkeyCoordinator.wakeShortcut.name): \(model.hotkeyCoordinator.wakeShortcut.trigger)")
                        Text("\(model.hotkeyCoordinator.stopShortcut.name): \(model.hotkeyCoordinator.stopShortcut.trigger)")
                        Text("\(model.hotkeyCoordinator.cancelShortcut.name): \(model.hotkeyCoordinator.cancelShortcut.trigger)")
                        Text("\(model.hotkeyCoordinator.rewriteModifierHint.name): \(model.hotkeyCoordinator.rewriteModifierHint.trigger)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("快捷键配置") {
                    VStack(alignment: .leading, spacing: 10) {
                        KeyboardShortcuts.Recorder("唤醒 / 开始", name: .wakeSession)
                        KeyboardShortcuts.Recorder("停止 / 提交", name: .stopSession)
                        KeyboardShortcuts.Recorder("取消会话", name: .cancelSession)

                        if let shortcutConflictWarning {
                            Label(shortcutConflictWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Label("未发现快捷键冲突。", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        HStack {
                            Button("恢复默认快捷键") {
                                KeyboardShortcuts.reset(.wakeSession, .stopSession, .cancelSession)
                            }

                            Spacer()

                            Text("全局快捷键会立即生效。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("权限中心") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(permissionsCenter.presentationItems()) { item in
                            PermissionRowView(
                                item: item,
                                onRequest: { permissionsCenter.requestAccess(for: item.id) },
                                onOpenSettings: { permissionsCenter.openSystemSettings(for: item.id) }
                            )
                        }

                        if permissionsCenter.snapshot.hasBlockingIssue {
                            Label("当前存在权限缺失，语音会话无法开始。", systemImage: "xmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Label("权限条件已满足，可开始语音会话。", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }

                        Button("刷新权限状态") {
                            permissionsCenter.refreshStatuses()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("按应用场景策略") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("按前台应用调整输出风格与默认通道行为，策略仅保留在本地。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline) {
                            Text("当前应用：\(focusedAppContext.appName)")
                                .font(.subheadline.weight(.semibold))

                            Spacer()

                            Button("刷新当前应用") {
                                refreshFocusedAppPolicyEditor()
                            }
                        }

                        Text(focusedAppContext.bundleID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Label(
                            focusedPolicyIsStored
                                ? "该应用已启用自定义策略。"
                                : "该应用暂无自定义策略，正在使用启发式默认值。",
                            systemImage: focusedPolicyIsStored ? "slider.horizontal.3" : "sparkles"
                        )
                        .font(.caption)
                        .foregroundStyle(focusedPolicyIsStored ? .green : .secondary)

                        Picker("默认输出风格", selection: $focusedAppOutputBias) {
                            ForEach(AppOutputBias.allCases) { bias in
                                Text(bias.displayName).tag(bias)
                            }
                        }
                        .pickerStyle(.menu)

                        Toggle(
                            "当存在选区时优先改写",
                            isOn: $focusedAppPreferSelectionRewrite
                        )

                        HStack {
                            Button("保存策略") {
                                saveFocusedAppPolicy()
                            }

                            Button("删除自定义策略", role: .destructive) {
                                removeFocusedAppPolicy()
                            }
                            .disabled(!focusedPolicyIsStored)
                        }

                        Divider()

                        Text("已保存的应用策略")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if customPolicies.isEmpty {
                            Text("暂无自定义应用策略。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(customPolicies) { policy in
                                    AppPolicyRowView(
                                        policy: policy,
                                        onOutputBiasChange: { newBias in
                                            updatePolicy(policy, outputBias: newBias)
                                        },
                                        onPreferSelectionRewriteChange: { enabled in
                                            updatePolicy(policy, preferSelectionRewrite: enabled)
                                        },
                                        onDelete: {
                                            appScenePolicyStore.removePolicy(bundleID: policy.bundleID)
                                            if policy.bundleID == focusedAppContext.bundleID {
                                                refreshFocusedAppPolicyEditor()
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("本地历史") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("会话记录仅保留在本机，可逐条删除，也可全部清理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Picker("模式", selection: $historyModeFilter) {
                                ForEach(HistoryModeFilter.allCases) { filter in
                                    Text(filter.displayName).tag(filter)
                                }
                            }
                            .pickerStyle(.menu)

                            Picker("状态", selection: $historyStatusFilter) {
                                ForEach(HistoryStatusFilter.allCases) { filter in
                                    Text(filter.displayName).tag(filter)
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        TextField("按应用名或 bundle id 过滤", text: $historyAppQuery)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()

                        Toggle(
                            "仅显示当前应用（\(focusedAppContext.appName)）",
                            isOn: $historyOnlyFocusedApp
                        )

                        if filteredHistoryEntries.isEmpty {
                            Text("暂无历史记录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredHistoryEntries) { entry in
                                    HistoryEntryRowView(
                                        entry: entry,
                                        onDelete: {
                                            localHistoryStore.delete(entryID: entry.id)
                                        }
                                    )
                                }
                            }
                        }

                        HStack {
                            Text("显示 \(filteredHistoryEntries.count) / \(localHistoryStore.entries.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("删除全部历史", role: .destructive) {
                                localHistoryStore.clearAll()
                            }
                            .disabled(localHistoryStore.entries.isEmpty)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("本地数据目录") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.localStore.rootDirectory.path)
                        Text(model.localStore.historyDirectory.path)
                        Text(model.localStore.diagnosticsDirectory.path)
                        Text(model.localStore.temporaryAudioDirectory.path)
                    }
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("诊断信息") {
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
            providerSettingsStore.refreshCredentialState()
            refreshFocusedAppPolicyEditor()
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
            return "唤醒与停止使用了同一快捷键，可能导致状态误切换。"
        }

        if wake != nil && wake == cancel {
            return "唤醒与取消使用了同一快捷键，会话控制会变得不明确。"
        }

        if stop != nil && stop == cancel {
            return "停止与取消使用了同一快捷键，建议分开以降低误触。"
        }

        return nil
    }

    private var editingProfileName: String {
        providerSettingsStore.editingProfile?.name ?? "当前配置"
    }

    private var editingProfileType: ProviderType {
        providerSettingsStore.editingProfile?.type ?? .openAICompatible
    }

    private var editingProfileNameBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.editingProfile?.name ?? "" },
            set: { providerSettingsStore.updateEditingProfileName($0) }
        )
    }

    private var editingProfileTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.editingProfile?.type ?? .openAICompatible },
            set: { providerSettingsStore.updateEditingProfileType($0) }
        )
    }

    private var editingProfileEnabledBinding: Binding<Bool> {
        Binding(
            get: { providerSettingsStore.editingProfile?.isEnabled ?? false },
            set: { providerSettingsStore.updateEditingProfileEnabled($0) }
        )
    }

    private var editingBaseURLBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.editingProfile?.baseURLString ?? "" },
            set: { providerSettingsStore.updateEditingBaseURL($0) }
        )
    }

    private var editingTranscriptionModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.editingProfile?.transcriptionModelName ?? "" },
            set: { providerSettingsStore.updateEditingTranscriptionModel($0) }
        )
    }

    private var editingRewriteModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.editingProfile?.rewriteModelName ?? "" },
            set: { providerSettingsStore.updateEditingRewriteModel($0) }
        )
    }

    private var focusedPolicyIsStored: Bool {
        appScenePolicyStore.hasStoredPolicy(bundleID: focusedAppContext.bundleID)
    }

    private var customPolicies: [AppScenePolicy] {
        appScenePolicyStore.policies.sorted {
            if $0.appName == $1.appName {
                return $0.bundleID < $1.bundleID
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private var filteredHistoryEntries: [SessionHistoryEntry] {
        localHistoryStore.entries
            .filter { entry in
                historyModeFilter.matches(entry.mode)
            }
            .filter { entry in
                historyStatusFilter.matches(entry.status)
            }
            .filter { entry in
                guard historyOnlyFocusedApp else {
                    return true
                }
                return entry.bundleID == focusedAppContext.bundleID
            }
            .filter { entry in
                let query = historyAppQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    return true
                }
                let lowered = query.lowercased()
                return entry.appName.lowercased().contains(lowered) || entry.bundleID.lowercased().contains(lowered)
            }
            .prefix(50)
            .map { $0 }
    }

    private func refreshFocusedAppPolicyEditor() {
        let context = model.contextDetector.focusedAppContext()
        let policy = appScenePolicyStore.policy(for: context)
        focusedAppContext = context
        focusedAppOutputBias = policy.outputBias
        focusedAppPreferSelectionRewrite = policy.preferSelectionRewrite
    }

    private func saveFocusedAppPolicy() {
        appScenePolicyStore.upsertPolicy(
            for: focusedAppContext,
            outputBias: focusedAppOutputBias,
            preferSelectionRewrite: focusedAppPreferSelectionRewrite
        )
        refreshFocusedAppPolicyEditor()
    }

    private func removeFocusedAppPolicy() {
        appScenePolicyStore.removePolicy(bundleID: focusedAppContext.bundleID)
        refreshFocusedAppPolicyEditor()
    }

    private func updatePolicy(
        _ policy: AppScenePolicy,
        outputBias: AppOutputBias? = nil,
        preferSelectionRewrite: Bool? = nil
    ) {
        appScenePolicyStore.upsertPolicy(
            appName: policy.appName,
            bundleID: policy.bundleID,
            outputBias: outputBias ?? policy.outputBias,
            preferSelectionRewrite: preferSelectionRewrite ?? policy.preferSelectionRewrite
        )

        if policy.bundleID == focusedAppContext.bundleID {
            refreshFocusedAppPolicyEditor()
        }
    }

    private var apiKeyStatusText: String {
        switch providerSettingsStore.credentialState {
        case .saved:
            return "\(editingProfileName) 的 API 密钥已写入钥匙串。"
        case .missing:
            return "\(editingProfileName) 暂无 API 密钥。"
        }
    }

    private var apiKeyStatusIcon: String {
        switch providerSettingsStore.credentialState {
        case .saved:
            return "lock.shield.fill"
        case .missing:
            return "exclamationmark.shield.fill"
        }
    }

    private var apiKeyStatusColor: Color {
        switch providerSettingsStore.credentialState {
        case .saved:
            return .green
        case .missing:
            return .orange
        }
    }

    private var feedbackColor: Color {
        guard let feedbackMessage = providerSettingsStore.feedbackMessage?.lowercased() else {
            return .secondary
        }
        if feedbackMessage.contains("无法") || feedbackMessage.contains("失败") {
            return .red
        }
        return .secondary
    }
}

private enum HistoryModeFilter: String, CaseIterable, Identifiable {
    case all
    case dictation
    case selectionRewrite

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "全部模式"
        case .dictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
        }
    }

    func matches(_ mode: SessionHistoryMode) -> Bool {
        switch self {
        case .all:
            return true
        case .dictation:
            return mode == .dictation
        case .selectionRewrite:
            return mode == .selectionRewrite
        }
    }
}

private enum HistoryStatusFilter: String, CaseIterable, Identifiable {
    case all
    case success
    case failed
    case cancelled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            return "全部状态"
        case .success:
            return "成功"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    func matches(_ status: SessionHistoryStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .success:
            return status == .success
        case .failed:
            return status == .failed
        case .cancelled:
            return status == .cancelled
        }
    }
}

private struct AppPolicyRowView: View {
    let policy: AppScenePolicy
    let onOutputBiasChange: (AppOutputBias) -> Void
    let onPreferSelectionRewriteChange: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(policy.appName)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button("删除", role: .destructive) {
                    onDelete()
                }
                .font(.caption)
            }

            Text(policy.bundleID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Picker("输出风格", selection: Binding(
                get: { policy.outputBias },
                set: { onOutputBiasChange($0) }
            )) {
                ForEach(AppOutputBias.allCases) { bias in
                    Text(bias.displayName).tag(bias)
                }
            }
            .pickerStyle(.menu)

            Toggle(
                "优先选区改写",
                isOn: Binding(
                    get: { policy.preferSelectionRewrite },
                    set: { onPreferSelectionRewriteChange($0) }
                )
            )
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct HistoryEntryRowView: View {
    let entry: SessionHistoryEntry
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Label(statusLabel, systemImage: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Button("删除", role: .destructive) {
                    onDelete()
                }
                .font(.caption)
            }

            Text("\(modeLabel) · \(entry.appName)")
                .font(.subheadline.weight(.semibold))

            Text(entry.bundleID)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let instruction = entry.instructionText, !instruction.isEmpty {
                Text("指令：\(instruction)")
                    .font(.caption)
                    .lineLimit(2)
            }

            if !entry.inputText.isEmpty {
                Text("输入：\(entry.inputText)")
                    .font(.caption)
                    .lineLimit(2)
            }

            if let outputText = entry.outputText, !outputText.isEmpty {
                Text("输出：\(outputText)")
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }

            if !providerLine.isEmpty {
                Text(providerLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var modeLabel: String {
        switch entry.mode {
        case .dictation:
            return "普通听写"
        case .selectionRewrite:
            return "选区改写"
        }
    }

    private var statusLabel: String {
        switch entry.status {
        case .success:
            return "成功"
        case .failed:
            return "失败"
        case .cancelled:
            return "已取消"
        }
    }

    private var statusIcon: String {
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

    private var providerLine: String {
        var parts: [String] = []
        if let transcriptionProvider = entry.transcriptionProvider, !transcriptionProvider.isEmpty {
            if let transcriptionModel = entry.transcriptionModel, !transcriptionModel.isEmpty {
                parts.append("转写：\(transcriptionProvider) · \(transcriptionModel)")
            } else {
                parts.append("转写：\(transcriptionProvider)")
            }
        }
        if let rewriteProvider = entry.rewriteProvider, !rewriteProvider.isEmpty {
            if let rewriteModel = entry.rewriteModel, !rewriteModel.isEmpty {
                parts.append("改写：\(rewriteProvider) · \(rewriteModel)")
            } else {
                parts.append("改写：\(rewriteProvider)")
            }
        }
        return parts.joined(separator: " | ")
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
