import AppKit
import Combine
import EventKit
import KeyboardShortcuts
import SwiftUI

enum MemoryToolbarLayoutMode: Equatable {
    case singleRow
    case stacked

    static func resolve(
        availableWidth: CGFloat,
        filterBarWidth: CGFloat,
        clearButtonWidth: CGFloat,
        spacing: CGFloat
    ) -> Self {
        guard availableWidth > 0, filterBarWidth > 0, clearButtonWidth > 0 else {
            return .singleRow
        }

        let requiredWidth = filterBarWidth + clearButtonWidth + spacing
        return requiredWidth <= availableWidth ? .singleRow : .stacked
    }
}

private enum MemoryToolbarMeasureID: Hashable {
    case container
    case filterBar
    case clearButton
}

private struct MemoryToolbarWidthPreferenceKey: PreferenceKey {
    static var defaultValue: [MemoryToolbarMeasureID: CGFloat] = [:]

    static func reduce(
        value: inout [MemoryToolbarMeasureID: CGFloat],
        nextValue: () -> [MemoryToolbarMeasureID: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private extension View {
    func reportMemoryToolbarWidth(_ id: MemoryToolbarMeasureID) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MemoryToolbarWidthPreferenceKey.self,
                    value: [id: proxy.size.width]
                )
            }
        )
    }
}

struct SettingsView: View {
    let model: AppModel
    private let runtimePolicy = AppRuntimePolicy.current()

    @ObservedObject private var controlCenterState: ControlCenterState
    @ObservedObject private var hotkeyStateStore: HotkeyStateStore
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var asrDictionaryStore: ASRDictionaryStore
    @ObservedObject private var mailAddressBookStore: MailAddressBookStore
    @ObservedObject private var localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager
    @ObservedObject private var skillRuleStore: SkillRuleStore
    @ObservedObject private var appScenePolicyStore: AppScenePolicyStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore
    @ObservedObject private var brainstormDurationProfileStore: BrainstormDurationProfileStore
    @ObservedObject private var toastPresenter: ToastPresenter
    @ObservedObject private var magicianFeatureToggleStore: MagicianFeatureToggleStore
    @StateObject private var mailAddressBookPanelModel: MailAddressBookPanelModel

    @State private var asrTesting = false
    @State private var textTesting = false
    @State private var cliTextTesting = false
    @State private var showClearMemoryConfirmation = false
    @State private var sceneSearchQuery = ""
    @State private var scenePromptDraft = ""
    @State private var sceneEditingBundleID: String?
    @State private var sceneEditingAppName = ""
    @State private var discoveredApps: [SceneAppOption] = []
    @State private var isDiscoveringApps = false
    @State private var debouncedToastTask: Task<Void, Never>?
    @State private var debouncedSceneSaveTask: Task<Void, Never>?
    @State private var dictionaryDraft = ""
    @State private var wakeModifierCaptureState: ModifierCaptureStateMachine?
    @State private var wakeModifierFlagsMonitor: Any?
    @State private var wakeModifierKeyDownMonitor: Any?
    @State private var brainstormModifierCaptureState: ModifierCaptureStateMachine?
    @State private var brainstormFlagsMonitor: Any?
    @State private var brainstormKeyDownMonitor: Any?
    @State private var magicianPermissionPrompt: MagicianPermissionPromptModel?
    @State private var showingMailAddressBookSheet = false
    @State private var magicianEventAuthorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var magicianShortcutsAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts")
    @State private var magicianCreateNoteShortcutName = MagicianCreateNoteShortcutSupport().shortcutName
    @State private var magicianCreateNoteShortcutExists = MagicianCreateNoteShortcutSupport().hasShortcut()
    @State private var magicianNotesAppAvailable = MagicianNotesCapability.notesAppAvailable
    @State private var magicianComposeEmailAvailable = MagicianMailCapability.composeEmailServiceAvailable
    @State private var magicianMailtoAvailable = MagicianMailCapability.mailtoAvailable
    @State private var magicianMailAppAvailable = MagicianMailCapability.mailAppAvailable
    @State private var magicianMusicAppAvailable = MagicianMusicCapability.musicAppAvailable
    @State private var magicianFeishuCLIAvailable = FeishuCLIProvider.detectAvailability().isAvailable
    @State private var magicianFeishuCLICommandName = FeishuCLIProvider.detectAvailability().commandName ?? "未检测到"
    @State private var magicianFeishuCLIResolvedPath = FeishuCLIProvider.detectAvailability().backend?.executablePath ?? "未检测到"
    @State private var magicianFeishuCLIHealth: MagicianFeishuCLIHealth = .unknown
    @State private var magicianCLIAuthChecking = false
    @State private var magicianCLIDoctorChecking = false
    @State private var magicianCLIScopeFixing = false
    @State private var memoryToolbarAvailableWidth: CGFloat = 0
    @State private var memoryFilterBarWidth: CGFloat = 0
    @State private var clearMemoryButtonWidth: CGFloat = 0
    @State private var timeMachineItems: [V4TimeItem] = []

    private let magicianStatusResolver = MagicianStatusResolver()
    private let magicianCapabilityProbe = MagicianCapabilityProbe()

    init(model: AppModel) {
        self.model = model
        _controlCenterState = ObservedObject(wrappedValue: model.controlCenterState)
        _hotkeyStateStore = ObservedObject(wrappedValue: model.hotkeyStateStore)
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _asrDictionaryStore = ObservedObject(wrappedValue: model.asrDictionaryStore)
        _mailAddressBookStore = ObservedObject(wrappedValue: model.mailAddressBookStore)
        _localSenseVoiceRuntimeManager = ObservedObject(wrappedValue: model.localSenseVoiceRuntimeManager)
        _skillRuleStore = ObservedObject(wrappedValue: model.skillRuleStore)
        _appScenePolicyStore = ObservedObject(wrappedValue: model.appScenePolicyStore)
        _localHistoryStore = ObservedObject(wrappedValue: model.localHistoryStore)
        _brainstormDurationProfileStore = ObservedObject(wrappedValue: model.brainstormDurationProfileStore)
        _toastPresenter = ObservedObject(wrappedValue: model.toastPresenter)
        _magicianFeatureToggleStore = ObservedObject(wrappedValue: model.magicianFeatureToggleStore)
        _mailAddressBookPanelModel = StateObject(
            wrappedValue: MailAddressBookPanelModel(store: model.mailAddressBookStore)
        )
    }

    var body: some View {
        NavigationSplitView {
            List(DesktopSection.allCases, selection: $controlCenterState.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 188, ideal: 204, max: 220)
            .navigationTitle("PulseType")
        } detail: {
            ZStack {
                detailPaneBackground
                    .ignoresSafeArea()

                Group {
                    switch controlCenterState.selectedSection {
                    case .home:
                        homePage
                    case .memory:
                        memoryPage
                    case .magician:
                        magicianPage
                    case .skills:
                        skillsPage
                    case .agentBrainstorm:
                        agentBrainstormPage
                    case .dictionary:
                        dictionaryPage
                    case .model:
                        modelPage
                    case .timeMachine:
                        timeMachinePage
                    case .settings:
                        settingsPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let toast = toastPresenter.message {
                    VStack {
                        Spacer()
                        PulseToastView(text: toast.text)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, 24)
                    .animation(.spring(response: 0.28, dampingFraction: 0.86), value: toast.id)
                }
            }
        }
        .onReceive(hotkeyStateStore.$latestChangeMessage.compactMap { $0 }) { message in
            showToast(message)
            hotkeyStateStore.clearLatestChangeMessage()
        }
        .onChange(of: controlCenterState.selectedSection) { _, section in
            if section == .dictionary {
                dictionaryDraft = asrDictionaryStore.rawText
            } else if section == .agentBrainstorm {
                hotkeyStateStore.refresh()
                model.interactionCoordinator.ensureBrainstormDurationProfile()
            } else if section == .timeMachine {
                refreshTimeMachineItems()
            } else if section == .magician {
                refreshMagicianCapabilityState()
                permissionsCenter.refreshStatuses()
            } else if brainstormModifierCaptureState != nil {
                stopBrainstormCapture()
            }
        }
        .onChange(of: providerSettingsStore.asrConfig.providerType) { _, _ in
            guard controlCenterState.selectedSection == .agentBrainstorm else {
                return
            }
            model.interactionCoordinator.ensureBrainstormDurationProfile()
        }
        .onChange(of: providerSettingsStore.asrConfig.modelName) { _, _ in
            guard controlCenterState.selectedSection == .agentBrainstorm else {
                return
            }
            model.interactionCoordinator.ensureBrainstormDurationProfile()
        }
        .onChange(of: providerSettingsStore.feishuCLIExecutablePathOverride) { _, _ in
            guard controlCenterState.selectedSection == .magician else {
                return
            }
            refreshMagicianCapabilityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshMagicianCapabilityState()
        }
        .sheet(item: $magicianPermissionPrompt) { prompt in
            MagicianPermissionSheetView(
                prompt: prompt,
                onPrimary: { handleMagicianPromptPrimary(prompt) },
                onCancel: { magicianPermissionPrompt = nil }
            )
        }
        .sheet(isPresented: $showingMailAddressBookSheet) {
            MailAddressBookManagementSheetView(
                model: mailAddressBookPanelModel,
                onOutcome: { outcome in
                    if let message = outcome.toastText {
                        showToast(message)
                    }
                },
                onClose: { showingMailAddressBookSheet = false }
            )
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(title: "首页")

                homeProductIntroCard

                LazyVGrid(columns: homeMetricColumns, spacing: 12) {
                    HomeMetricCard(
                        title: "历史对话时长",
                        value: durationText(controlCenterState.homeStatsSnapshot.totalDialogueDurationSeconds),
                        subtitle: "仅统计成功听写"
                    )
                    HomeMetricCard(
                        title: "历史输入字数",
                        value: "\(controlCenterState.homeStatsSnapshot.totalInputCharacters)",
                        subtitle: "累计写入字符"
                    )
                    HomeMetricCard(
                        title: "平均速度",
                        value: HomeStatsFormatter.speedText(snapshot: controlCenterState.homeStatsSnapshot),
                        subtitle: "字/分钟（真实时长）"
                    )
                    HomeMetricCard(
                        title: "总计节省时间",
                        value: durationText(controlCenterState.homeStatsSnapshot.savedTypingSeconds),
                        subtitle: "相对打字效率估算"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 22)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
        }
    }

    private var memoryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(
                    title: "记忆",
                    subtitle: "这里会保存会话与执行轨迹。现在支持只清空记录，或一键清洗全部旧使用数据。"
                )

                memoryToolbar

                if filteredHistoryEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("当前筛选下还没有记录。", systemImage: "tray")
                            .font(.subheadline.weight(.semibold))
                        Text("先回首页进行一次语音会话，完成后就会出现记录。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .pulseCard(cornerRadius: 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredHistoryEntries) { entry in
                            MemoryRowView(
                                entry: entry,
                                onCopyPrimary: { copyPrimaryMemoryText(entry) },
                                onCopyDialogue: { copyBrainstormDialogueText(entry) },
                                onCopyRaw: { copyRawMemoryText(entry) },
                                onCopyCommand: { copyInstructionMemoryText(entry) },
                                onDelete: {
                                    localHistoryStore.delete(entryID: entry.id)
                                    showToast("已删除一条记录。")
                                }
                            )
                            .padding(12)
                            .pulseCard(cornerRadius: 12)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .confirmationDialog(
            "确认清空记录？",
            isPresented: $showClearMemoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("仅清空记忆页记录") {
                localHistoryStore.clearAll()
                showToast("会话明细已清空，首页累计指标保持不变。")
            }
            .keyboardShortcut(.defaultAction)
            Button("深度清洗全部旧使用数据", role: .destructive) {
                model.purgeAllUsageData()
                refreshTimeMachineItems()
                showToast("旧会话、时光机、历史轨迹与诊断日志已清空。")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("第一项只清空记忆页。第二项会同时清空时光机、历史轨迹和诊断日志。")
        }
    }

    private var magicianPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "魔术先生",
                    subtitle: "默认走 V4 主链。这里展示当前能稳定执行的能力入口。"
                )

                magicianNativeFeatureBoard
                magicianCLIControlCard
                magicianSkillUploadCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            refreshMagicianCapabilityState()
            permissionsCenter.refreshStatuses()
        }
    }

    private var magicianNativeFeatureBoard: some View {
        let textScope = MagicianPermissionScope.textProcessing
        let textResolution = magicianStatusResolver.resolve(
            feature: .textTransform,
            isEnabled: magicianFeatureToggleStore.isEnabled(textScope),
            dependencies: currentMagicianDependencies
        )

        return VStack(alignment: .leading, spacing: 8) {
            Text("原生功能")
                .font(.headline)
            HStack(spacing: 12) {
                Text("文本处理 / 原生动作")
                    .font(.subheadline)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { magicianFeatureToggleStore.isEnabled(textScope) },
                        set: { enabled in
                            handleMagicianScopeToggleChange(scope: textScope, enabled: enabled)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .scaleEffect(0.8)
                .fixedSize()
            }

            Text("日历 / 备忘录 / 邮件 / 音乐")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("长按主键（默认右 Shift）说命令，松开执行。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reason = textResolution.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var magicianCLIControlCard: some View {
        let sharedScope = MagicianPermissionScope.textProcessing
        let resolution = magicianStatusResolver.resolve(
            feature: .textTransform,
            isEnabled: magicianFeatureToggleStore.isEnabled(sharedScope),
            dependencies: currentMagicianDependencies
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text("skill")
                    .font(.headline)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { magicianFeatureToggleStore.isEnabled(sharedScope) },
                        set: { enabled in
                            handleMagicianScopeToggleChange(scope: sharedScope, enabled: enabled)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .scaleEffect(0.8)
                .fixedSize()
            }

            Text("skill 用来接外部 Agent 能力（例如飞书）。这个开关与上面的“文本处理 / 原生动作”共用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let reason = resolution.reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var magicianSkillUploadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地 skill 文件")
                .font(.headline)
            Text("当前版本不提供界面上传。请把 skill 放到应用约定目录，重启后会自动识别。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var feishuSupportTierGroups: [(tier: FeishuOperationSupportTier, operations: [FeishuOperationDescriptor])] {
        FeishuOperationCatalog.groupedBySupportTier()
    }

    private var feishuHealthColor: Color {
        switch magicianFeishuCLIHealth {
        case .ready:
            return .green
        case .permissionLimited:
            return .orange
        case .authRequired, .unavailable:
            return .red
        case .unknown:
            return .secondary
        }
    }

    private var feishuHealthSymbolName: String {
        switch magicianFeishuCLIHealth {
        case .ready:
            return "checkmark.seal.fill"
        case .permissionLimited:
            return "exclamationmark.shield.fill"
        case .authRequired:
            return "person.crop.circle.badge.exclamationmark"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var magicianCLIExecutablePathBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.feishuCLIExecutablePathOverride },
            set: { newValue in
                providerSettingsStore.updateFeishuCLIExecutablePathOverride(newValue)
                refreshMagicianCapabilityState()
            }
        )
    }

    private enum FeishuCLIQuickCheckMode {
        case auth
        case doctor
        case scopeFix
    }

    private func runFeishuCLIQuickCheck(
        arguments: [String],
        mode: FeishuCLIQuickCheckMode
    ) {
        let availability = currentFeishuCLIAvailability()
        guard let backend = availability.backend else {
            showToast("未检测到飞书 CLI，请先安装或填写可执行路径。")
            return
        }

        switch mode {
        case .auth:
            magicianCLIAuthChecking = true
        case .doctor:
            magicianCLIDoctorChecking = true
        case .scopeFix:
            magicianCLIScopeFixing = true
        }

        Task {
            let result = await runProcessWithTimeout(
                executablePath: backend.executablePath,
                arguments: arguments,
                timeoutSeconds: 14,
                maxOutputCharacters: 2_600,
                environment: FeishuCLIProvider.buildProcessEnvironment(
                    executablePath: backend.executablePath
                )
            )
            await MainActor.run {
                let output = !result.stdout.isEmpty ? result.stdout : result.stderr
                let concise = output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n")
                    .prefix(2)
                    .joined(separator: " | ")
                if result.exitCode == 0 {
                    showToast(concise.isEmpty ? "检查完成。" : concise)
                } else {
                    showToast("检查失败（\(result.exitCode)）：\(concise.isEmpty ? "请打开日志查看详情。" : concise)")
                }
                refreshMagicianCapabilityState()
                switch mode {
                case .auth:
                    magicianCLIAuthChecking = false
                case .doctor:
                    magicianCLIDoctorChecking = false
                case .scopeFix:
                    magicianCLIScopeFixing = false
                }
            }
        }
    }

    private func runFeishuCLIScopeFix(_ scopes: [String]) {
        let uniqueScopes = Array(Set(scopes)).sorted()
        guard !uniqueScopes.isEmpty else {
            showToast("当前没有待补 scope。")
            return
        }
        var arguments = ["auth", "login", "--no-wait"]
        for scope in uniqueScopes {
            arguments.append("--scope")
            arguments.append(scope)
        }
        runFeishuCLIQuickCheck(
            arguments: arguments,
            mode: .scopeFix
        )
    }

    private var mailAssistantAddressBookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("邮箱名库", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(mailAddressBookStore.entries.count) 条")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.66))
                    )
            }

            Text("系统会先用你自己的名库匹配联系人，再在必要时用文本模型推断新地址。地址不够稳时，只打开 Mail 编辑窗口，不会直接发。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("管理邮箱名库") {
                showingMailAddressBookSheet = true
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.48))
        )
    }

    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(
                    title: "Now you see me",
                    subtitle: "这里是你的自定义区：表达风格、规则偏好、场景策略都在这。"
                )

                ForEach(skillRuleStore.visibleRules()) { rule in
                    SkillRuleCardView(
                        ruleID: rule.id,
                        title: rule.id.title,
                        subtitle: rule.id.subtitle,
                        isEnabled: Binding(
                            get: { skillRuleStore.rule(for: rule.id).isEnabled },
                            set: { enabled in
                                skillRuleStore.setEnabled(enabled, for: rule.id)
                                showToast("\(rule.id.title)现在已经\(enabled ? "开启" : "关闭")。")
                            }
                        ),
                        parameter: Binding(
                            get: { skillRuleStore.rule(for: rule.id).parameter },
                            set: { parameter in
                                skillRuleStore.setParameter(parameter, for: rule.id)
                                scheduleDebouncedToast("\(rule.id.title)已更新并生效。")
                            }
                        ),
                        parameterPlaceholder: rule.id == .systemPrompt
                            ? "例如：默认更简洁、保留重点、避免过度客套"
                            : "例如：嗯,啊,就是,那个,然后"
                    )
                }

                scenePolicySkillsCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var modelPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "模型",
                    subtitle: "三槽位：语音识别 / 文本处理 / CLI Agent。改动会实时生效。"
                )

                modelRoleSection(
                    roleTitle: "语音识别",
                    cardTitle: "语音识别",
                    availableProviderTypes: asrProviderOptions,
                    providerType: asrProviderTypeBinding,
                    baseURL: asrBaseURLBinding,
                    modelName: asrModelBinding,
                    localModelPath: providerSettingsStore.asrConfig.providerType == .localSenseVoice
                        ? asrLocalModelPathBinding
                        : nil,
                    showsBaseURL: providerSettingsStore.asrConfig.providerType != .localSenseVoice,
                    showsAPIKey: providerSettingsStore.asrConfig.providerType.requiresAPIKey,
                    allowsCustomBaseURL: providerSettingsStore.asrConfig.providerType.allowsCustomBaseURL,
                    baseURLPlaceholder: baseURLPlaceholder(for: providerSettingsStore.asrConfig.providerType),
                    modelPlaceholder: providerSettingsStore.asrConfig.providerType.defaultTranscriptionModelName,
                    apiKeyDraft: $providerSettingsStore.asrAPIKeyDraft,
                    credentialState: providerSettingsStore.asrCredentialState,
                    validationMessage: providerSettingsStore.asrConfigurationValidationMessage,
                    feedbackMessage: providerSettingsStore.asrFeedbackMessage,
                    onSaveKey: saveASRKey,
                    onDeleteKey: deleteASRKey,
                    isTesting: asrTesting,
                    testButtonTitle: "测试 ASR",
                    latestResult: providerSettingsStore.latestASRTestResult,
                    activeConfigLine: effectiveConfigLine(
                        providerType: providerSettingsStore.asrConfig.providerType,
                        baseURLString: providerSettingsStore.asrConfig.baseURLString,
                        modelName: providerSettingsStore.asrConfig.modelName,
                        localModelPath: providerSettingsStore.asrConfig.localModelPath
                    ),
                    showsLocalSenseVoiceRuntimeDetails: true,
                    onTest: runASRTest
                )

                modelRoleSection(
                    roleTitle: "文本处理",
                    cardTitle: "文本处理",
                    availableProviderTypes: textProviderOptions,
                    providerType: textProviderTypeBinding,
                    baseURL: textBaseURLBinding,
                    modelName: textModelBinding,
                    localModelPath: nil,
                    showsBaseURL: true,
                    showsAPIKey: true,
                    allowsCustomBaseURL: providerSettingsStore.textConfig.providerType.allowsCustomBaseURL,
                    baseURLPlaceholder: baseURLPlaceholder(for: providerSettingsStore.textConfig.providerType),
                    modelPlaceholder: providerSettingsStore.textConfig.providerType.defaultRewriteModelName,
                    apiKeyDraft: $providerSettingsStore.textAPIKeyDraft,
                    credentialState: providerSettingsStore.textCredentialState,
                    validationMessage: providerSettingsStore.textConfigurationValidationMessage,
                    feedbackMessage: providerSettingsStore.textFeedbackMessage,
                    onSaveKey: saveTextKey,
                    onDeleteKey: deleteTextKey,
                    isTesting: textTesting,
                    testButtonTitle: "测试文本模型",
                    latestResult: providerSettingsStore.latestTextTestResult,
                    activeConfigLine: effectiveConfigLine(
                        providerType: providerSettingsStore.textConfig.providerType,
                        baseURLString: providerSettingsStore.textConfig.baseURLString,
                        modelName: providerSettingsStore.textConfig.modelName
                    ),
                    showsLocalSenseVoiceRuntimeDetails: false,
                    onTest: runTextTest
                )

                modelRoleSection(
                    roleTitle: "CLI 模式（Agent）",
                    cardTitle: "CLI 模式（Agent）",
                    availableProviderTypes: textProviderOptions,
                    providerType: cliProviderTypeBinding,
                    baseURL: cliBaseURLBinding,
                    modelName: cliModelBinding,
                    localModelPath: nil,
                    showsBaseURL: true,
                    showsAPIKey: true,
                    allowsCustomBaseURL: providerSettingsStore.cliTextConfig.providerType.allowsCustomBaseURL,
                    baseURLPlaceholder: baseURLPlaceholder(for: providerSettingsStore.cliTextConfig.providerType),
                    modelPlaceholder: providerSettingsStore.cliTextConfig.providerType.defaultRewriteModelName,
                    apiKeyDraft: $providerSettingsStore.cliTextAPIKeyDraft,
                    credentialState: providerSettingsStore.cliTextCredentialState,
                    validationMessage: providerSettingsStore.cliTextConfigurationValidationMessage,
                    feedbackMessage: providerSettingsStore.cliTextFeedbackMessage,
                    onSaveKey: saveCLITextKey,
                    onDeleteKey: deleteCLITextKey,
                    isTesting: cliTextTesting,
                    testButtonTitle: "测试 CLI 文本模型",
                    latestResult: providerSettingsStore.latestCLITextTestResult,
                    activeConfigLine: effectiveConfigLine(
                        providerType: providerSettingsStore.cliTextConfig.providerType,
                        baseURLString: providerSettingsStore.cliTextConfig.baseURLString,
                        modelName: providerSettingsStore.cliTextConfig.modelName
                    ),
                    showsLocalSenseVoiceRuntimeDetails: false,
                    onTest: runCLITextTest
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            providerSettingsStore.refreshCredentialState()
            Task {
                await localSenseVoiceRuntimeManager.detect(
                    modelDirectoryPath: providerSettingsStore.asrConfig.localModelPath
                )
            }
        }
    }

    private var dictionaryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "词典",
                    subtitle: "每行一个词条，可写专业词或短语。保存后会立刻用于语音识别。"
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("词典内容")
                        .font(.headline)

                    TextEditor(text: $dictionaryDraft)
                        .font(.system(size: 13))
                        .frame(minHeight: 220, maxHeight: 320)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                        )

                    HStack(alignment: .center, spacing: 12) {
                        Button("保存") {
                            saveDictionary()
                        }
                        .buttonStyle(.borderedProminent)

                        Text(dictionaryStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .pulseCard(cornerRadius: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            dictionaryDraft = asrDictionaryStore.rawText
        }
    }

    @ViewBuilder
    private func modelRoleSection(
        roleTitle: String,
        cardTitle: String,
        availableProviderTypes: [ProviderType],
        providerType: Binding<ProviderType>,
        baseURL: Binding<String>,
        modelName: Binding<String>,
        localModelPath: Binding<String>?,
        showsBaseURL: Bool,
        showsAPIKey: Bool,
        allowsCustomBaseURL: Bool,
        baseURLPlaceholder: String,
        modelPlaceholder: String,
        apiKeyDraft: Binding<String>,
        credentialState: ProviderSettingsStore.CredentialState,
        validationMessage: String?,
        feedbackMessage: String?,
        onSaveKey: @escaping () -> Void,
        onDeleteKey: @escaping () -> Void,
        isTesting: Bool,
        testButtonTitle: String,
        latestResult: ConnectionTestResult?,
        activeConfigLine: String,
        showsLocalSenseVoiceRuntimeDetails: Bool,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text(roleTitle)
                    .font(.headline)
                Label(
                    providerType.wrappedValue.displayName,
                    systemImage: providerType.wrappedValue == .localSenseVoice ? "cpu" : "cloud.fill"
                )
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                )
                .foregroundStyle(providerType.wrappedValue == .localSenseVoice ? .orange : .accentColor)
                Spacer()
            }

            ModelConfigCard(
                title: cardTitle,
                availableProviderTypes: availableProviderTypes,
                providerType: providerType,
                baseURL: baseURL,
                modelName: modelName,
                localModelPath: localModelPath,
                showsBaseURL: showsBaseURL,
                showsAPIKey: showsAPIKey,
                allowsCustomBaseURL: allowsCustomBaseURL,
                baseURLPlaceholder: baseURLPlaceholder,
                modelPlaceholder: modelPlaceholder,
                apiKeyDraft: apiKeyDraft,
                credentialState: credentialState,
                validationMessage: validationMessage,
                feedbackMessage: feedbackMessage,
                onSaveKey: onSaveKey,
                onDeleteKey: onDeleteKey
            )

            if
                showsLocalSenseVoiceRuntimeDetails,
                providerType.wrappedValue == .localSenseVoice
            {
                localSenseVoiceRuntimeInlineSection
            }

            LabeledContent("当前生效配置", value: activeConfigLine)
                .font(.caption)

            HStack {
                Button(isTesting ? "\(testButtonTitle)中..." : testButtonTitle) {
                    onTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isTesting)
                Spacer()
            }

            if let latestResult {
                ConnectionTestSummaryView(title: "最近一次测试", result: latestResult)
                Label(
                    "建议：\(actionSuggestion(for: latestResult))",
                    systemImage: latestResult.status == .success
                        ? "checkmark.seal.fill"
                        : "lightbulb.fill"
                )
                .font(.caption)
                .foregroundStyle(latestResult.status == .success ? .green : .secondary)
            } else {
                Text("还没有测试记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var localSenseVoiceRuntimeInlineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地运行信息")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("模型目录", value: providerSettingsStore.asrConfig.localModelPath ?? defaultSenseVoiceModelPath)
                LabeledContent("运行环境", value: localSenseVoiceRuntimeManager.runtimeRootPath)
                LabeledContent("当前状态", value: localSenseVoiceRuntimeManager.currentStatusText)
                if let manifest = localSenseVoiceRuntimeManager.manifest {
                    LabeledContent("当前后端", value: manifest.backend)
                    LabeledContent("Python", value: manifest.pythonPath)
                }
                if let lastCheckedAt = localSenseVoiceRuntimeManager.lastCheckedAt {
                    LabeledContent(
                        "最近检测",
                        value: lastCheckedAt.formatted(date: .omitted, time: .standard)
                    )
                }
            }
            .font(.caption)

            HStack {
                Button("准备环境") {
                    Task {
                        await localSenseVoiceRuntimeManager.prepare(
                            modelDirectoryPath: providerSettingsStore.asrConfig.localModelPath
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparingLocalSenseVoice)

                Button("重新检测") {
                    Task {
                        await localSenseVoiceRuntimeManager.detect(
                            modelDirectoryPath: providerSettingsStore.asrConfig.localModelPath
                        )
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isPreparingLocalSenseVoice)

                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.06))
        )
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "设置",
                    subtitle: "管理快捷键、权限与基础环境。"
                )

                hotkeySettingsCard
                permissionSettingsCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
            providerSettingsStore.refreshCredentialState()
            hotkeyStateStore.refresh()
        }
        .onDisappear {
            stopWakeModifierCapture()
            stopBrainstormCapture()
        }
    }

    private var agentBrainstormPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "一口气全念对",
                    subtitle: "用于短时讨论记录，自动整理成可直接给 AI 使用的上下文。"
                )

                brainstormIntroCard
                brainstormTriggerCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            hotkeyStateStore.refresh()
            model.interactionCoordinator.ensureBrainstormDurationProfile()
        }
        .onDisappear {
            stopBrainstormCapture()
        }
    }

    private var brainstormIntroCard: some View {
        let profile = currentBrainstormDurationProfile
        return VStack(alignment: .leading, spacing: 8) {
            Text("这个功能能帮你什么")
                .font(.headline)
            Label("多人聊完一个想法后，可直接生成能发给 AI 的上下文。", systemImage: "person.2")
                .font(.subheadline)
            Label("自动理清讨论重点，减少你手动补背景。", systemImage: "text.bubble")
                .font(.subheadline)
            Label("整理结果会放进输入框和剪贴板，下一问马上接上。", systemImage: "doc.on.clipboard")
                .font(.subheadline)
            Divider()
            Text("当前模型实测上限：\(profile.maxSeconds) 秒")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("推荐时长：\(profile.recommendedSeconds) 秒以内")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var brainstormTriggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("触发层")
                .font(.headline)

            brainstormModifierSection(
                title: "双击修饰键",
                currentText: "当前触发：双击 \(hotkeyStateStore.brainstormModifier.displayName)"
            )

            if let conflict = hotkeyStateStore.conflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("触发配置可用。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private func brainstormModifierSection(
        title: String,
        currentText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ModifierCaptureButton(
                valueText: brainstormModifierCaptureState?.pendingModifier?.displayName ?? hotkeyStateStore.brainstormModifier.displayName,
                isCapturing: brainstormModifierCaptureState != nil,
                action: startBrainstormModifierCapture
            )

            if let brainstormCaptureHint = brainstormModifierCaptureState?.hint {
                Text(brainstormCaptureHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("点击上面的括号区域后，按左/右修饰键，再按 Enter 确认，按 Esc 取消。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(currentText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷键")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("主键（开始/停止）")
                    .font(.subheadline.weight(.semibold))
                VStack(alignment: .leading, spacing: 8) {
                    Text("单键触发按键")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ModifierCaptureButton(
                        valueText: wakeModifierCaptureState?.pendingModifier?.displayName ?? hotkeyStateStore.wakeModifier.displayName,
                        isCapturing: wakeModifierCaptureState != nil,
                        action: startWakeModifierCapture
                    )

                    if let wakeModifierCaptureHint = wakeModifierCaptureState?.hint {
                        Text(wakeModifierCaptureHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("点击上面的括号区域后，按左/右修饰键，再按 Enter 确认，按 Esc 取消。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("当前主键：单键触发 · \(hotkeyStateStore.wakeModifier.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("取消键")
                    .font(.subheadline.weight(.semibold))
                Text("取消键固定为 Esc，不支持修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("触发规则说明")
                    .font(.subheadline.weight(.semibold))
                Text("主键单击：普通语音开始/停止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("主键长按（≥180ms）：进入魔术先生，按住说话，松开执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("一口气全念对键双击（≤350ms）：进入一口气全念对。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("当主键与一口气全念对键相同：双击优先一口气全念对，长按优先魔术先生，单击普通语音。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let conflict = hotkeyStateStore.conflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("两个快捷键没有冲突。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var permissionSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("权限中心")
                .font(.headline)

            ForEach(permissionsCenter.presentationItems()) { item in
                PermissionRowView(
                    item: item,
                    onRequest: { permissionsCenter.requestAccess(for: item.id) },
                    onOpenSettings: { permissionsCenter.openSystemSettings(for: item.id) }
                )
            }

            HStack {
                Button("重新检测权限") {
                    permissionsCenter.refreshStatuses()
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            if permissionsCenter.runtimeDiagnostics.bundlePath != runtimePolicy.installPath {
                Label(
                    "当前不是 \(runtimePolicy.installPath)。建议用安装脚本覆盖到 \(runtimePolicy.installURL.deletingLastPathComponent().path)，避免权限反复重置。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var scenePolicySkillsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按应用风格")
                        .font(.headline)
                    Text("给每个应用设独立表达风格，写出来的话更贴场景。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { skillRuleStore.rule(for: .appPreferenceBoost).isEnabled },
                        set: { enabled in
                            skillRuleStore.setEnabled(enabled, for: .appPreferenceBoost)
                            showToast("按应用风格现在已经\(enabled ? "开启" : "关闭")。")
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .scaleEffect(0.8)
                .fixedSize()
            }

            Text("关闭总开关后，所有应用都会用同一套表达风格。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("搜索应用名或 Bundle ID（来源：已安装 + 运行中）", text: $sceneSearchQuery)
                    .textFieldStyle(.roundedBorder)
            }

            if isDiscoveringApps {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("正在拉取应用列表…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !filteredDiscoveredApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(filteredDiscoveredApps.prefix(8))) { app in
                        SceneAppCandidateRowView(
                            app: app,
                            onAdd: {
                                addScenePolicy(from: app)
                            }
                        )
                    }
                }
            } else if !sceneSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("没有匹配结果，请换个关键词。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if sortedScenePolicies.isEmpty {
                Text("还没有策略。先在上面搜索应用并添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedScenePolicies) { policy in
                    ScenePolicyRowView(
                        policy: policy,
                        isEditing: sceneEditingBundleID == policy.bundleID,
                        onEdit: { beginEditingScenePolicy(policy) },
                        onDelete: { removeScenePolicy(policy) }
                    )
                }
            }

            if let editingPolicy = currentEditingScenePolicy {
                VStack(alignment: .leading, spacing: 6) {
                    Text("编辑提示词：\(editingPolicy.appName)")
                        .font(.subheadline.weight(.semibold))
                    Text(editingPolicy.bundleID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    TextEditor(text: $scenePromptDraft)
                        .font(.system(size: 13))
                        .frame(minHeight: 88, maxHeight: 130)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                        )
                    HStack {
                        Button("完成编辑") {
                            autoSaveScenePolicyIfPossible()
                            sceneEditingBundleID = nil
                            sceneEditingAppName = ""
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            } else {
                Text("点“编辑”后即可输入该应用专属提示词，保存会自动生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
        .onAppear {
            loadDiscoveredApps()
        }
        .onChange(of: scenePromptDraft) { _, _ in
            scheduleScenePolicyAutosave()
        }
    }

    private var homeProductIntroCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("核心特点")
                .font(.headline)

            Label("比敲键盘更轻松，也比普通语音输入法更懂你的表达习惯，目标是把日常输入慢慢变成纯语音交互。", systemImage: "text.bubble")
                .font(.subheadline)
            Label("本地模型和云端模型一起工作，历史与配置默认留在本地，效果和安全感可以一起兼顾。", systemImage: "lock.shield")
                .font(.subheadline)
            Label("长按主键唤起魔术先生，翻译、润色、日程、备忘录、邮件一句搞定。", systemImage: "wand.and.stars")
                .font(.subheadline)
            Label("双击主键进入一口气全念对，特别适合多人讨论和短会议纪要，边聊边记也能快速理清重点。", systemImage: "brain.head.profile")
                .font(.subheadline)
            Label("不同应用可配不同提示词和风格，聊天、邮件、文档各有各的语气，满足多元场景需求。", systemImage: "arrow.triangle.2.circlepath.circle")
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var homeMetricColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 240, maximum: 360),
                spacing: 12,
                alignment: .top
            )
        ]
    }

    private var currentBrainstormDurationProfile: BrainstormDurationProfile {
        let normalizedModel = providerSettingsStore.modelName
        let modelName = normalizedModel.isEmpty
            ? providerSettingsStore.asrConfig.modelName
            : normalizedModel
        return brainstormDurationProfileStore.effectiveProfile(
            for: providerSettingsStore.asrConfig.providerType,
            modelName: modelName
        )
    }

    private var asrProviderTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.asrConfig.providerType },
            set: {
                providerSettingsStore.updateASRProviderType($0)
                showToast("语音识别服务商已切换，现在已经生效。")
            }
        )
    }

    private var dictionaryStatusLine: String {
        let preview = asrDictionaryStore.preview(rawText: dictionaryDraft)
        let extra = preview.didTruncate ? "（超长将自动截断注入）" : ""
        return "总行数 \(rawDictionaryLineCount) · 有效词条 \(preview.effectiveTerms.count) · 注入长度 \(preview.injectedCharacterCount)\(extra)"
    }

    private var rawDictionaryLineCount: Int {
        let normalized = dictionaryDraft.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.isEmpty else {
            return 0
        }
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    private var textProviderTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.textConfig.providerType },
            set: {
                providerSettingsStore.updateTextProviderType($0)
                showToast("文本处理服务商已切换，现在已经生效。")
            }
        )
    }

    private var cliProviderTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.cliTextConfig.providerType },
            set: {
                providerSettingsStore.updateCLITextProviderType($0)
                showToast("CLI 模式服务商已切换，现在已经生效。")
            }
        )
    }

    private var asrBaseURLBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.asrConfig.baseURLString },
            set: {
                providerSettingsStore.updateASRBaseURL($0)
                scheduleDebouncedToast("语音识别地址已更新并生效。")
            }
        )
    }

    private var textBaseURLBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.textConfig.baseURLString },
            set: {
                providerSettingsStore.updateTextBaseURL($0)
                scheduleDebouncedToast("文本处理地址已更新并生效。")
            }
        )
    }

    private var cliBaseURLBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.cliTextConfig.baseURLString },
            set: {
                providerSettingsStore.updateCLITextBaseURL($0)
                scheduleDebouncedToast("CLI 模式地址已更新并生效。")
            }
        )
    }

    private var asrModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.asrConfig.modelName },
            set: {
                providerSettingsStore.updateASRModel($0)
                scheduleDebouncedToast("语音识别模型已更新并生效。")
            }
        )
    }

    private var asrLocalModelPathBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.asrConfig.localModelPath ?? defaultSenseVoiceModelPath },
            set: {
                providerSettingsStore.updateASRLocalModelPath($0)
                scheduleDebouncedToast("本地模型目录已更新并生效。")
            }
        )
    }

    private var textModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.textConfig.modelName },
            set: {
                providerSettingsStore.updateTextModel($0)
                scheduleDebouncedToast("文本处理模型已更新并生效。")
            }
        )
    }

    private var cliModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.cliTextConfig.modelName },
            set: {
                providerSettingsStore.updateCLITextModel($0)
                scheduleDebouncedToast("CLI 模式模型已更新并生效。")
            }
        )
    }

    private var asrProviderOptions: [ProviderType] {
        ProviderType.allCases.filter(\.supportsTranscription)
    }

    private var textProviderOptions: [ProviderType] {
        ProviderType.allCases.filter(\.supportsRewrite)
    }

    private var detailPaneBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.white.opacity(0.58),
                Color(nsColor: .controlBackgroundColor).opacity(0.36)
            ],
            startPoint: .top,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private func pageHeader(title: String, subtitle: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func pageHeader<Accessory: View>(
        title: String,
        subtitle: String = "",
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 12)

            accessory()
        }
    }

    private var currentMagicianDependencies: MagicianDependencySnapshot {
        MagicianDependencySnapshot(
            accessibilityState: permissionsCenter.snapshot.accessibility,
            eventAuthorizationStatus: magicianEventAuthorizationStatus,
            shortcutsCLIAvailable: magicianShortcutsAvailable,
            createNoteShortcutName: magicianCreateNoteShortcutName,
            createNoteShortcutExists: magicianCreateNoteShortcutExists,
            notesAppAvailable: magicianNotesAppAvailable,
            composeEmailAvailable: magicianComposeEmailAvailable,
            mailtoAvailable: magicianMailtoAvailable,
            mailAppAvailable: magicianMailAppAvailable,
            musicAppAvailable: magicianMusicAppAvailable,
            feishuCLIAvailable: magicianFeishuCLIAvailable,
            feishuCLICommandName: magicianFeishuCLICommandName
        )
    }

    private func currentFeishuCLIAvailability() -> FeishuCLIAvailability {
        FeishuCLIProvider.detectAvailability(
            executableOverride: providerSettingsStore.resolvedFeishuCLIExecutablePathOverride
        )
    }

    private func refreshMagicianCapabilityState() {
        let shortcutSupport = MagicianCreateNoteShortcutSupport()
        magicianEventAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        magicianShortcutsAvailable = shortcutSupport.cliAvailable
        magicianCreateNoteShortcutName = shortcutSupport.shortcutName
        magicianCreateNoteShortcutExists = shortcutSupport.hasShortcut(named: magicianCreateNoteShortcutName)
        magicianNotesAppAvailable = MagicianNotesCapability.notesAppAvailable
        magicianComposeEmailAvailable = MagicianMailCapability.composeEmailServiceAvailable
        magicianMailtoAvailable = MagicianMailCapability.mailtoAvailable
        magicianMailAppAvailable = MagicianMailCapability.mailAppAvailable
        magicianMusicAppAvailable = MagicianMusicCapability.musicAppAvailable
        let feishuAvailability = currentFeishuCLIAvailability()
        magicianFeishuCLIAvailable = feishuAvailability.isAvailable
        magicianFeishuCLICommandName = feishuAvailability.commandName ?? "未检测到"
        magicianFeishuCLIResolvedPath = feishuAvailability.backend?.executablePath ?? "未检测到"
        magicianFeishuCLIHealth = feishuAvailability.isAvailable
            ? .unknown
            : .unavailable(message: "未检测到 feishu 或 lark-cli。")

        Task {
            let result = await magicianCapabilityProbe.probeFeishuCLI(
                executableOverride: providerSettingsStore.resolvedFeishuCLIExecutablePathOverride
            )
            await MainActor.run {
                magicianFeishuCLIAvailable = result.availability.isAvailable
                magicianFeishuCLICommandName = result.availability.commandName ?? "未检测到"
                magicianFeishuCLIResolvedPath = result.availability.backend?.executablePath ?? "未检测到"
                magicianFeishuCLIHealth = result.health
            }
        }
    }

    private func handleMagicianScopeToggleChange(
        scope: MagicianPermissionScope,
        enabled: Bool
    ) {
        magicianFeatureToggleStore.setEnabled(enabled, for: scope)
        showToast("\(scope.displayName)能力已\(enabled ? "开启" : "关闭")。")
    }

    private func handleMagicianPromptPrimary(_ prompt: MagicianPermissionPromptModel) {
        Task {
            await performMagicianPermissionAction(prompt.primaryAction)
            await MainActor.run {
                permissionsCenter.refreshStatuses()
                refreshMagicianCapabilityState()
                let requirement = magicianStatusResolver.requirement(
                    for: prompt.feature,
                    dependencies: currentMagicianDependencies
                )
                switch requirement {
                case .ready:
                    magicianFeatureToggleStore.setEnabled(true, for: prompt.feature)
                    showToast("\(prompt.feature.displayName)已开启。")
                case let .blocked(reason, _):
                    magicianFeatureToggleStore.setEnabled(false, for: prompt.feature)
                    showToast(reason)
                }
                magicianPermissionPrompt = nil
            }
        }
    }

    private func performMagicianPermissionAction(_ action: MagicianPermissionAction) async {
        switch action {
        case .requestAccessibility:
            await MainActor.run {
                permissionsCenter.requestAccess(for: .accessibility)
            }
        case .requestCalendarAccess:
            let granted = await requestCalendarAccessIfNeeded()
            if !granted {
                guard
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
                    )
                else {
                    return
                }
                _ = await MainActor.run {
                    NSWorkspace.shared.open(url)
                }
            }
        case let .openSystemSettings(urlString):
            guard let url = URL(string: urlString) else {
                return
            }
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        case let .openExternalURL(urlString):
            guard let url = URL(string: urlString) else {
                return
            }
            _ = await MainActor.run {
                NSWorkspace.shared.open(url)
            }
        case .openShortcutsApp:
            await MainActor.run {
                openApplication(
                    bundleIdentifier: "com.apple.shortcuts",
                    fallbackPath: "/System/Applications/Shortcuts.app"
                )
            }
        case .openNotesApp:
            await MainActor.run {
                openApplication(
                    bundleIdentifier: "com.apple.Notes",
                    fallbackPath: "/System/Applications/Notes.app"
                )
            }
        case .openMailApp:
            await MainActor.run {
                openApplication(
                    bundleIdentifier: "com.apple.mail",
                    fallbackPath: "/System/Applications/Mail.app"
                )
            }
        case .openMusicApp:
            await MainActor.run {
                openApplication(
                    bundleIdentifier: "com.apple.Music",
                    fallbackPath: "/System/Applications/Music.app"
                )
            }
        }
    }

    private func requestCalendarAccessIfNeeded() async -> Bool {
        let eventStore = EKEventStore()
        return await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func openApplication(
        bundleIdentifier: String,
        fallbackPath: String
    ) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
            return
        }

        let fallbackURL = URL(fileURLWithPath: fallbackPath, isDirectory: true)
        NSWorkspace.shared.open(fallbackURL)
    }

    private func baseURLPlaceholder(for type: ProviderType) -> String {
        if type == .localSenseVoice {
            return "本地模式无需接口地址"
        }
        if type.allowsCustomBaseURL {
            return type == .openAICompatible
                ? "https://api.deepseek.com"
                : "https://your-openai-compatible.com"
        }
        return "\(type.fixedBaseURL?.absoluteString ?? "https://api.openai.com")（固定）"
    }

    private var isPreparingLocalSenseVoice: Bool {
        if case .preparing = localSenseVoiceRuntimeManager.state {
            return true
        }
        return false
    }

    private var filteredHistoryEntries: [SessionHistoryEntry] {
        localHistoryStore.entries(matching: controlCenterState.memoryFilter)
    }

    private func durationText(_ seconds: Double) -> String {
        let safeSeconds = max(0, Int(seconds.rounded()))
        let minutes = safeSeconds / 60
        let remainSeconds = safeSeconds % 60
        return "\(minutes)分 \(remainSeconds)秒"
    }

    private func effectiveConfigLine(
        providerType: ProviderType,
        baseURLString: String,
        modelName: String,
        localModelPath: String? = nil
    ) -> String {
        if providerType == .localSenseVoice {
            let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalModel = normalizedModel.isEmpty ? "模型未填写" : normalizedModel
            let normalizedPath = localModelPath?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finalPath = (normalizedPath?.isEmpty == false)
                ? normalizedPath!
                : defaultSenseVoiceModelPath
            return "\(providerType.shortLabel) · 本地模型 · \(finalModel) · \(finalPath)"
        }
        let resolvedBaseURL = ProviderConfigurationValidator.resolvedBaseURL(
            providerType: providerType,
            baseURLString: baseURLString
        )?.absoluteString ?? "地址无效"
        let normalizedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalModel = normalizedModel.isEmpty ? "模型未填写" : normalizedModel
        return "\(providerType.shortLabel) · \(resolvedBaseURL) · \(finalModel)"
    }

    private func actionSuggestion(for result: ConnectionTestResult) -> String {
        if result.status == .success {
            return "配置可用，回到首页就可以开始语音输入。"
        }

        if let status = result.httpStatus {
            switch status {
            case 401, 403:
                return "请核对 API Key 是否正确、是否过期，并确认模型权限。"
            case 404:
                return "请核对 API 地址和模型名，确认接口兼容 OpenAI 路径。"
            case 429:
                return "请检查额度或限频策略，稍后再试。"
            case 500...599:
                return "服务端临时异常，稍后重试并查看服务状态页。"
            default:
                break
            }
        }

        if result.message.contains("密钥") || result.hint.contains("密钥") {
            return "先保存有效 API Key，再重新测试。"
        }

        if result.message.contains("接口地址") || result.hint.contains("接口地址") {
            return "请确认 Base URL 以 http/https 开头，且指向可用网关。"
        }

        if result.message.contains("模型") || result.hint.contains("模型") {
            return "请确认模型名与服务端可用模型一致。"
        }

        if result.message.contains("网络") || result.hint.contains("网络") {
            return "请检查网络、代理或防火墙，再重试。"
        }

        return "建议依次检查地址、模型名、密钥、额度和网络。"
    }

    private var memoryFilters: [LocalHistoryFilter] {
        [.all, .dictation, .selectionRewrite, .brainstorm, .failed]
    }

    private var memoryFilterBar: some View {
        Picker("记忆筛选", selection: $controlCenterState.memoryFilter) {
            ForEach(memoryFilters) { filter in
                Text(filter.title)
                    .tag(filter)
                }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .reportMemoryToolbarWidth(.filterBar)
    }

    private var clearMemoryButton: some View {
        Button("清理数据", role: .destructive) {
            showClearMemoryConfirmation = true
        }
        .buttonStyle(.bordered)
        .disabled(!hasAnyPurgeableUsageData)
        .reportMemoryToolbarWidth(.clearButton)
    }

    private var memoryToolbarLayoutMode: MemoryToolbarLayoutMode {
        MemoryToolbarLayoutMode.resolve(
            availableWidth: memoryToolbarAvailableWidth,
            filterBarWidth: memoryFilterBarWidth,
            clearButtonWidth: clearMemoryButtonWidth,
            spacing: 12
        )
    }

    private var memoryToolbar: some View {
        Group {
            switch memoryToolbarLayoutMode {
            case .singleRow:
                HStack(spacing: 12) {
                    memoryFilterBar
                    Spacer(minLength: 12)
                    clearMemoryButton
                }
            case .stacked:
                VStack(alignment: .leading, spacing: 10) {
                    memoryFilterBar
                    HStack {
                        Spacer()
                        clearMemoryButton
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .reportMemoryToolbarWidth(.container)
        .onPreferenceChange(MemoryToolbarWidthPreferenceKey.self, perform: updateMemoryToolbarMeasurements)
    }

    private func updateMemoryToolbarMeasurements(_ widths: [MemoryToolbarMeasureID: CGFloat]) {
        if let containerWidth = widths[.container], abs(memoryToolbarAvailableWidth - containerWidth) > 0.5 {
            memoryToolbarAvailableWidth = containerWidth
        }
        if let filterBarWidth = widths[.filterBar], abs(memoryFilterBarWidth - filterBarWidth) > 0.5 {
            memoryFilterBarWidth = filterBarWidth
        }
        if let clearButtonWidth = widths[.clearButton], abs(clearMemoryButtonWidth - clearButtonWidth) > 0.5 {
            clearMemoryButtonWidth = clearButtonWidth
        }
    }

    private var hasAnyPurgeableUsageData: Bool {
        if !localHistoryStore.entries.isEmpty {
            return true
        }
        if !timeMachineItems.isEmpty {
            return true
        }
        let fileManager = FileManager.default
        let timeMachineFile = V4TimeMachineStore.storageURL(historyDirectory: model.localStore.historyDirectory)
        if fileManager.fileExists(atPath: timeMachineFile.path) {
            return true
        }
        let legacyDirectories = [
            model.localStore.rootDirectory.appendingPathComponent("MagicianNative", isDirectory: true),
            model.localStore.rootDirectory.appendingPathComponent("MagicianV2", isDirectory: true)
        ]
        return legacyDirectories.contains(where: { fileManager.fileExists(atPath: $0.path) })
    }

    private var timeMachinePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(
                    title: "时光机",
                    subtitle: "这里是本地提醒与时间相关记忆的总览。"
                )

                timeMachineOverviewCard

                if timeMachineItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("当前还没有时光机记录。", systemImage: "clock.badge.questionmark")
                            .font(.subheadline.weight(.semibold))
                        Text("你可以对魔术先生说“30 分钟后提醒我…”或“记一下…”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .pulseCard(cornerRadius: 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(timeMachineItems.prefix(120)) { item in
                            timeMachineRow(item)
                                .padding(12)
                                .pulseCard(cornerRadius: 12)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            refreshTimeMachineItems()
        }
    }

    private var timeMachineOverviewCard: some View {
        let total = timeMachineItems.count
        let scheduled = timeMachineItems.filter { $0.status == .scheduled }.count
        let failed = timeMachineItems.filter { $0.status == .scheduleFailed }.count
        let latest = timeMachineItems.first?.createdAt

        return VStack(alignment: .leading, spacing: 10) {
            Text("概览")
                .font(.headline)
            HStack(spacing: 12) {
                Label("总记录 \(total)", systemImage: "tray.full")
                    .font(.caption)
                Label("已定时 \(scheduled)", systemImage: "checkmark.circle")
                    .font(.caption)
                Label("失败 \(failed)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            if let latest {
                Text("最近写入：\(latest.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("刷新时光机") {
                    refreshTimeMachineItems()
                    showToast("时光机列表已刷新。")
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private func timeMachineRow(_ item: V4TimeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(item.normalizedText.isEmpty ? item.rawCommand : item.normalizedText)
                    .font(.headline)
                Spacer()
                Text(timeMachineStatusText(item.status))
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(timeMachineStatusColor(item.status).opacity(0.16))
                    )
                    .foregroundStyle(timeMachineStatusColor(item.status))
            }

            Text("创建时间：\(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let scheduledAt = item.scheduledAt {
                Text("提醒时间：\(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !item.tags.isEmpty {
                Text("标签：\(item.tags.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshTimeMachineItems() {
        timeMachineItems = V4TimeMachineStore.loadItems(historyDirectory: model.localStore.historyDirectory)
    }

    private func timeMachineStatusText(_ status: V4TimeItemStatus) -> String {
        switch status {
        case .captured:
            return "已记录"
        case .scheduled:
            return "已定时"
        case .scheduleFailed:
            return "定时失败"
        case .cancelled:
            return "已取消"
        }
    }

    private func timeMachineStatusColor(_ status: V4TimeItemStatus) -> Color {
        switch status {
        case .captured:
            return .secondary
        case .scheduled:
            return .green
        case .scheduleFailed:
            return .orange
        case .cancelled:
            return .secondary
        }
    }

    private var sortedScenePolicies: [AppScenePolicy] {
        appScenePolicyStore.policies.sorted {
            $0.appName.localizedCompare($1.appName) == .orderedAscending
        }
    }

    private var filteredDiscoveredApps: [SceneAppOption] {
        let keyword = sceneSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !keyword.isEmpty else {
            return []
        }

        return discoveredApps.filter { app in
            app.appName.lowercased().contains(keyword)
                || app.bundleID.lowercased().contains(keyword)
        }
    }

    private var currentEditingScenePolicy: AppScenePolicy? {
        guard let bundleID = sceneEditingBundleID else {
            return nil
        }
        return appScenePolicyStore.policies.first(where: { $0.bundleID == bundleID })
    }

    private func beginEditingScenePolicy(_ policy: AppScenePolicy) {
        debouncedSceneSaveTask?.cancel()
        sceneEditingBundleID = policy.bundleID
        sceneEditingAppName = policy.appName
        scenePromptDraft = policy.appPrompt
        showToast("已进入 \(policy.appName) 的提示词编辑。")
    }

    private func removeScenePolicy(_ policy: AppScenePolicy) {
        appScenePolicyStore.removePolicy(bundleID: policy.bundleID)
        if sceneEditingBundleID == policy.bundleID {
            sceneEditingBundleID = nil
            sceneEditingAppName = ""
            scenePromptDraft = ""
        }
        showToast("已删除 \(policy.appName) 的策略。")
    }

    private func addScenePolicy(from app: SceneAppOption) {
        let existing = appScenePolicyStore.policies.first(where: { $0.bundleID == app.bundleID })
        appScenePolicyStore.upsertPolicy(
            appName: app.appName,
            bundleID: app.bundleID,
            appPrompt: existing?.appPrompt ?? ""
        )
        if let latest = appScenePolicyStore.policies.first(where: { $0.bundleID == app.bundleID }) {
            beginEditingScenePolicy(latest)
        }
        showToast("已添加 \(app.appName)，现在可编辑提示词。")
    }

    private func scheduleScenePolicyAutosave() {
        guard sceneEditingBundleID != nil else {
            return
        }

        debouncedSceneSaveTask?.cancel()
        debouncedSceneSaveTask = Task {
            try? await Task.sleep(nanoseconds: 520_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                autoSaveScenePolicyIfPossible()
            }
        }
    }

    private func autoSaveScenePolicyIfPossible() {
        guard let bundleID = sceneEditingBundleID else {
            return
        }

        let appName = sceneEditingAppName.trimmingCharacters(in: .whitespacesAndNewlines)
        let appPrompt = scenePromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty, !bundleID.isEmpty else {
            return
        }

        appScenePolicyStore.upsertPolicy(
            appName: appName,
            bundleID: bundleID,
            appPrompt: appPrompt
        )
        scheduleDebouncedToast("\(appName) 的应用提示词已更新并生效。")
    }

    private func loadDiscoveredApps() {
        if isDiscoveringApps {
            return
        }
        if !discoveredApps.isEmpty {
            return
        }
        isDiscoveringApps = true
        Task {
            let apps = await Task.detached(priority: .utility) {
                Self.discoverSceneApps()
            }.value
            let sorted = apps.sorted {
                $0.appName.localizedCompare($1.appName) == .orderedAscending
            }
            discoveredApps = Array(sorted.prefix(600))
            isDiscoveringApps = false
        }
    }

    nonisolated private static func discoverSceneApps() -> [SceneAppOption] {
        var map: [String: SceneAppOption] = [:]
        let selfBundleID = Bundle.main.bundleIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard
                let bundleID = app.bundleIdentifier,
                !bundleID.isEmpty
            else {
                continue
            }

            let appName = app.localizedName ?? bundleID
            SceneAppDiscovery.upsertCandidate(
                appName: appName,
                bundleID: bundleID,
                source: .running(activationPolicy: app.activationPolicy),
                selfBundleID: selfBundleID,
                map: &map
            )
        }

        let scanDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]

        for directory in scanDirectories {
            scanApplications(
                in: directory,
                depth: 0,
                maxDepth: 2,
                selfBundleID: selfBundleID,
                map: &map
            )
        }

        return Array(map.values)
    }

    nonisolated private static func scanApplications(
        in directory: URL,
        depth: Int,
        maxDepth: Int,
        selfBundleID: String?,
        map: inout [String: SceneAppOption]
    ) {
        guard depth <= maxDepth else {
            return
        }

        let fileManager = FileManager.default
        guard
            let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for child in children {
            let isAppBundle = child.pathExtension.lowercased() == "app"
            if isAppBundle {
                guard
                    let bundle = Bundle(url: child),
                    let bundleID = bundle.bundleIdentifier,
                    !bundleID.isEmpty
                else {
                    continue
                }

                let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? child.deletingPathExtension().lastPathComponent
                SceneAppDiscovery.upsertCandidate(
                    appName: appName,
                    bundleID: bundleID,
                    source: .installed,
                    selfBundleID: selfBundleID,
                    map: &map
                )
                continue
            }

            guard depth < maxDepth else {
                continue
            }

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue {
                scanApplications(
                    in: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    selfBundleID: selfBundleID,
                    map: &map
                )
            }
        }
    }

    private func copyPrimaryMemoryText(_ entry: SessionHistoryEntry) {
        let text: String?
        let emptyMessage: String
        let successMessage: String

        if entry.mode == .dictation {
            text = MemoryEntryTextResolver.primaryText(for: entry)
            emptyMessage = "这条记录没有主文本可复制。"
            successMessage = "已复制主文本。"
        } else if entry.mode == .brainstorm {
            text = MemoryEntryTextResolver.brainstormSummaryText(for: entry)
            emptyMessage = "这条脑暴记录没有结论可复制。"
            successMessage = "已复制结论。"
        } else if entry.mode == .selectionRewrite {
            text = MemoryEntryTextResolver.magicianPrimaryText(for: entry)
            emptyMessage = "这条魔术先生记录没有结果可复制。"
            successMessage = "已复制结果。"
        } else {
            text = MemoryEntryTextResolver.defaultText(for: entry)
            emptyMessage = "这条记录没有可复制的文本。"
            successMessage = "已复制文本。"
        }

        guard let text else {
            showToast(emptyMessage)
            return
        }

        writeTextToPasteboard(text)
        showToast(successMessage)
    }

    private func copyRawMemoryText(_ entry: SessionHistoryEntry) {
        switch entry.mode {
        case .dictation:
            guard let text = MemoryEntryTextResolver.rawText(for: entry) else {
                showToast("这条记录没有原始识别文本可复制。")
                return
            }
            writeTextToPasteboard(text)
            showToast("已复制原始识别文本。")
        case .brainstorm:
            guard let text = MemoryEntryTextResolver.brainstormRawText(for: entry) else {
                showToast("这条脑暴记录没有原始记录可复制。")
                return
            }
            writeTextToPasteboard(text)
            showToast("已复制原始记录。")
        case .selectionRewrite:
            guard let text = MemoryEntryTextResolver.magicianSecondaryText(for: entry) else {
                showToast("这条魔术先生记录没有原文可复制。")
                return
            }
            writeTextToPasteboard(text)
            showToast("已复制原文。")
        }
    }

    private func copyInstructionMemoryText(_ entry: SessionHistoryEntry) {
        guard entry.mode == .selectionRewrite else {
            showToast("当前模式没有命令文本。")
            return
        }

        guard let text = MemoryEntryTextResolver.magicianInstructionText(for: entry) else {
            showToast("这条魔术先生记录没有命令可复制。")
            return
        }

        writeTextToPasteboard(text)
        showToast("已复制命令。")
    }

    private func copyBrainstormDialogueText(_ entry: SessionHistoryEntry) {
        guard entry.mode == .brainstorm else {
            showToast("当前模式没有对话整理文本。")
            return
        }

        guard let text = MemoryEntryTextResolver.brainstormDialogueText(for: entry) else {
            showToast("这条脑暴记录没有对话整理文本可复制。")
            return
        }

        writeTextToPasteboard(text)
        showToast("已复制对话整理文本。")
    }

    private func writeTextToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showToast(_ message: String) {
        toastPresenter.show(message)
    }

    private func scheduleDebouncedToast(_ message: String) {
        debouncedToastTask?.cancel()
        debouncedToastTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                toastPresenter.show(message)
            }
        }
    }

    private func saveASRKey() {
        let isSuccess = providerSettingsStore.saveASRAPIKeyDraft()
        if let message = providerSettingsStore.asrFeedbackMessage {
            showToast(message)
        } else if isSuccess {
            showToast("语音识别 API 密钥已保存。")
        }
    }

    private func deleteASRKey() {
        providerSettingsStore.clearASRAPIKey()
        if let message = providerSettingsStore.asrFeedbackMessage {
            showToast(message)
        }
    }

    private func saveTextKey() {
        let isSuccess = providerSettingsStore.saveTextAPIKeyDraft()
        if let message = providerSettingsStore.textFeedbackMessage {
            showToast(message)
        } else if isSuccess {
            showToast("文本模型 API 密钥已保存。")
        }
    }

    private func deleteTextKey() {
        providerSettingsStore.clearTextAPIKey()
        if let message = providerSettingsStore.textFeedbackMessage {
            showToast(message)
        }
    }

    private func saveCLITextKey() {
        let isSuccess = providerSettingsStore.saveCLITextAPIKeyDraft()
        if let message = providerSettingsStore.cliTextFeedbackMessage {
            showToast(message)
        } else if isSuccess {
            showToast("CLI 模式 API 密钥已保存。")
        }
    }

    private func deleteCLITextKey() {
        providerSettingsStore.clearCLITextAPIKey()
        if let message = providerSettingsStore.cliTextFeedbackMessage {
            showToast(message)
        }
    }

    private func runASRTest() {
        guard !asrTesting else {
            return
        }
        asrTesting = true
        Task {
            _ = await providerSettingsStore.testASRConnection()
            await MainActor.run {
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
            _ = await providerSettingsStore.testTextConnection()
            await MainActor.run {
                textTesting = false
            }
        }
    }

    private func runCLITextTest() {
        guard !cliTextTesting else {
            return
        }
        cliTextTesting = true
        Task {
            _ = await providerSettingsStore.testCLITextConnection()
            await MainActor.run {
                cliTextTesting = false
            }
        }
    }

    private func saveDictionary() {
        let snapshot = asrDictionaryStore.save(rawText: dictionaryDraft)
        dictionaryDraft = asrDictionaryStore.rawText
        showToast("词典已保存并生效")
        if snapshot.didTruncate {
            NSLog(
                "[ASRDictionary] save preview truncated injected=%ld effective=%ld maxChars=%ld",
                snapshot.injectedTerms.count,
                snapshot.effectiveTerms.count,
                snapshot.maxCharacters
            )
        }
    }

    private func startWakeModifierCapture() {
        removeWakeModifierCaptureMonitors()
        stopBrainstormCapture()
        wakeModifierCaptureState = .start()

        wakeModifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            self.handleWakeModifierFlagsChanged(event)
            return event
        }

        wakeModifierKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleWakeModifierKeyDown(event)
        }
    }

    private func stopWakeModifierCapture() {
        removeWakeModifierCaptureMonitors()
        wakeModifierCaptureState = nil
    }

    private func removeWakeModifierCaptureMonitors() {
        if let wakeModifierFlagsMonitor {
            NSEvent.removeMonitor(wakeModifierFlagsMonitor)
            self.wakeModifierFlagsMonitor = nil
        }
        if let wakeModifierKeyDownMonitor {
            NSEvent.removeMonitor(wakeModifierKeyDownMonitor)
            self.wakeModifierKeyDownMonitor = nil
        }
    }

    private func handleWakeModifierFlagsChanged(_ event: NSEvent) {
        guard wakeModifierCaptureState != nil else {
            return
        }
        wakeModifierCaptureState?.applyFlagsChanged(keyCode: event.keyCode)
    }

    private func handleWakeModifierKeyDown(_ event: NSEvent) -> NSEvent? {
        guard var state = wakeModifierCaptureState else {
            return event
        }

        switch state.handleKeyDown(keyCode: event.keyCode) {
        case let .confirm(modifier):
            wakeModifierCaptureState = state
            let updated = hotkeyStateStore.setModifier(modifier, for: .wakeSession)
            guard updated else {
                showToast("主键不能与一口气全念对单击修饰键相同，请先调整一口气全念对触发键。")
                return nil
            }
            showToast("主键已改为单键触发 · \(modifier.displayName)。")
            stopWakeModifierCapture()
            return nil
        case .cancel:
            stopWakeModifierCapture()
            showToast("已取消主键修改。")
            return nil
        case .none:
            wakeModifierCaptureState = state
            return nil
        }
    }

    private func startBrainstormModifierCapture() {
        stopWakeModifierCapture()
        stopBrainstormCapture()
        brainstormModifierCaptureState = .start()

        brainstormFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            self.handleBrainstormModifierFlagsChanged(event)
            return event
        }
        brainstormKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.handleBrainstormModifierKeyDown(event)
        }
    }

    private func stopBrainstormCapture() {
        removeBrainstormCaptureMonitors()
        brainstormModifierCaptureState = nil
    }

    private func removeBrainstormCaptureMonitors() {
        if let brainstormFlagsMonitor {
            NSEvent.removeMonitor(brainstormFlagsMonitor)
            self.brainstormFlagsMonitor = nil
        }
        if let brainstormKeyDownMonitor {
            NSEvent.removeMonitor(brainstormKeyDownMonitor)
            self.brainstormKeyDownMonitor = nil
        }
    }

    private func handleBrainstormModifierFlagsChanged(_ event: NSEvent) {
        guard brainstormModifierCaptureState != nil else {
            return
        }
        brainstormModifierCaptureState?.applyFlagsChanged(keyCode: event.keyCode)
    }

    private func handleBrainstormModifierKeyDown(_ event: NSEvent) -> NSEvent? {
        guard var state = brainstormModifierCaptureState else {
            return event
        }

        switch state.handleKeyDown(keyCode: event.keyCode) {
        case let .confirm(modifier):
            brainstormModifierCaptureState = state
            hotkeyStateStore.setBrainstormModifier(modifier)
            showToast("一口气全念对修饰键已更新。")
            stopBrainstormCapture()
            return nil
        case .cancel:
            stopBrainstormCapture()
            showToast("已取消一口气全念对修饰键修改。")
            return nil
        case .none:
            brainstormModifierCaptureState = state
            return nil
        }
    }
}
