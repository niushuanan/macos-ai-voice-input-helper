import KeyboardShortcuts
import AppKit
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @ObservedObject private var controlCenterState: ControlCenterState
    @ObservedObject private var sessionStore: SessionStore
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var skillRuleStore: SkillRuleStore
    @ObservedObject private var appScenePolicyStore: AppScenePolicyStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore

    @State private var asrTesting = false
    @State private var textTesting = false
    @State private var memoryFeedback: String?
    @State private var settingsFeedback: String?
    @State private var sceneAppNameDraft = ""
    @State private var sceneBundleIDDraft = ""
    @State private var sceneOutputBiasDraft: AppOutputBias = .neutral
    @State private var scenePreferRewriteDraft = true

    init(model: AppModel) {
        self.model = model
        _controlCenterState = ObservedObject(wrappedValue: model.controlCenterState)
        _sessionStore = ObservedObject(wrappedValue: model.sessionStore)
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _skillRuleStore = ObservedObject(wrappedValue: model.skillRuleStore)
        _appScenePolicyStore = ObservedObject(wrappedValue: model.appScenePolicyStore)
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
            ZStack {
                detailPaneBackground
                    .ignoresSafeArea()

                Group {
                    switch controlCenterState.selectedSection {
                    case .home:
                        homePage
                    case .memory:
                        memoryPage
                    case .skills:
                        skillsPage
                    case .model:
                        modelPage
                    case .settings:
                        settingsPage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "首页",
                    subtitle: "主键开始语音，聆听中再次触发会停止并进入后续处理。"
                )

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
                .pulseCard(cornerRadius: 12)

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
            .frame(maxWidth: pageContentMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
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
                    subtitle: "这里会保存每次会话的本地记录，你可以筛选、复制或删除。"
                )

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
                                onCopy: { copyHistoryEntry(entry) },
                                onDelete: {
                                    localHistoryStore.delete(entryID: entry.id)
                                    memoryFeedback = "已删除一条记录。"
                                }
                            )
                            .padding(12)
                            .pulseCard(cornerRadius: 12)
                        }
                    }
                }
            }
            .frame(maxWidth: pageContentMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(
                    title: "技能",
                    subtitle: "技能默认本地生效。发生异常时会自动退回原始流程，不会卡住主链路。"
                )

                ForEach(skillRuleStore.rules) { rule in
                    SkillRuleCardView(
                        title: rule.id.title,
                        subtitle: rule.id.subtitle,
                        isEnabled: Binding(
                            get: { skillRuleStore.rule(for: rule.id).isEnabled },
                            set: { skillRuleStore.setEnabled($0, for: rule.id) }
                        ),
                        parameter: Binding(
                            get: { skillRuleStore.rule(for: rule.id).parameter },
                            set: { skillRuleStore.setParameter($0, for: rule.id) }
                        )
                    )
                }
            }
            .frame(maxWidth: pageContentMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }

    private var modelPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "模型",
                    subtitle: "先配置语音识别与文本处理，再点击测试。每次测试记录会持续显示。"
                )

                modelRoleSection(
                    roleTitle: "ASR（语音识别）",
                    cardTitle: "语音识别（ASR）",
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
                    onSaveKey: { providerSettingsStore.saveASRAPIKeyDraft() },
                    onDeleteKey: { providerSettingsStore.clearASRAPIKey() },
                    isTesting: asrTesting,
                    testButtonTitle: "测试 ASR",
                    latestResult: providerSettingsStore.latestASRTestResult,
                    activeConfigLine: effectiveConfigLine(
                        providerType: providerSettingsStore.asrConfig.providerType,
                        baseURLString: providerSettingsStore.asrConfig.baseURLString,
                        modelName: providerSettingsStore.asrConfig.modelName,
                        localModelPath: providerSettingsStore.asrConfig.localModelPath
                    ),
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
                    onSaveKey: { providerSettingsStore.saveTextAPIKeyDraft() },
                    onDeleteKey: { providerSettingsStore.clearTextAPIKey() },
                    isTesting: textTesting,
                    testButtonTitle: "测试文本模型",
                    latestResult: providerSettingsStore.latestTextTestResult,
                    activeConfigLine: effectiveConfigLine(
                        providerType: providerSettingsStore.textConfig.providerType,
                        baseURLString: providerSettingsStore.textConfig.baseURLString,
                        modelName: providerSettingsStore.textConfig.modelName
                    ),
                    onTest: runTextTest
                )
            }
            .frame(maxWidth: pageContentMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            providerSettingsStore.refreshCredentialState()
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
        onSaveKey: @escaping () -> Bool,
        onDeleteKey: @escaping () -> Bool,
        isTesting: Bool,
        testButtonTitle: String,
        latestResult: ConnectionTestResult?,
        activeConfigLine: String,
        onTest: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(roleTitle)
                .font(.headline)

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

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "设置",
                    subtitle: "在这里管理热键、权限、场景策略以及基础信息。"
                )

                hotkeySettingsCard
                permissionSettingsCard
                scenePolicySettingsCard
                aboutSettingsCard
            }
            .frame(maxWidth: pageContentMaxWidth, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
            providerSettingsStore.refreshCredentialState()
        }
    }

    private var hotkeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("热键设置")
                .font(.headline)

            KeyboardShortcuts.Recorder("主键（开始/停止）", name: .wakeSession)
            KeyboardShortcuts.Recorder("取消键", name: .cancelSession)

            if let conflict = shortcutConflictWarning {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("两个热键没有冲突。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Button("恢复默认") {
                    KeyboardShortcuts.reset(.wakeSession, .cancelSession)
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Text("交互规则：空闲时按主键开始语音；聆听中再按一次主键会停止并进入处理。取消键随时可中断。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
        }
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var scenePolicySettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("场景策略")
                .font(.headline)

            Text("按应用设置文风偏好与改写偏好。留空不影响主流程。")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("应用名（例如：Notion）", text: $sceneAppNameDraft)
                .textFieldStyle(.roundedBorder)
            TextField("Bundle ID（例如：notion.id）", text: $sceneBundleIDDraft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            Picker("文风偏好", selection: $sceneOutputBiasDraft) {
                ForEach(AppOutputBias.allCases) { bias in
                    Text(bias.displayName).tag(bias)
                }
            }
            .pickerStyle(.segmented)

            Toggle("优先选区改写", isOn: $scenePreferRewriteDraft)

            HStack {
                Button("保存策略") {
                    saveScenePolicy()
                }
                .buttonStyle(.borderedProminent)

                Button("清空输入") {
                    clearSceneDraft()
                }
                .buttonStyle(.bordered)

                Spacer()
            }

            if let settingsFeedback {
                Text(settingsFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appScenePolicyStore.policies.isEmpty {
                Text("还没有手动策略，系统会按应用类型使用默认偏好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appScenePolicyStore.policies.sorted { lhs, rhs in
                    lhs.appName.localizedCompare(rhs.appName) == .orderedAscending
                }) { policy in
                    ScenePolicyRowView(
                        policy: policy,
                        onLoad: { loadSceneDraft(policy) },
                        onDelete: {
                            appScenePolicyStore.removePolicy(bundleID: policy.bundleID)
                            settingsFeedback = "已删除 \(policy.appName) 的策略。"
                        }
                    )
                }
            }
        }
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private var aboutSettingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关于")
                .font(.headline)

            LabeledContent("应用名", value: "PulseType")
            LabeledContent("版本", value: appVersionLine)
            LabeledContent("产品定位", value: "macOS 桌面语音输入助手")
            LabeledContent("数据策略", value: "历史、配置、诊断默认保存在本地")
            LabeledContent("密钥策略", value: "API Key 仅存 macOS 钥匙串")
        }
        .padding(14)
        .pulseCard(cornerRadius: 12)
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
                    KeyboardShortcuts.reset(.wakeSession, .cancelSession)
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
                onSaveKey: { providerSettingsStore.saveASRAPIKeyDraft() },
                onDeleteKey: { providerSettingsStore.clearASRAPIKey() }
            )

            ModelConfigCard(
                title: "文本处理",
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

            if let asrTestResult = providerSettingsStore.latestASRTestResult {
                ConnectionTestSummaryView(title: "ASR 最近结果", result: asrTestResult)
            }

            if let textTestResult = providerSettingsStore.latestTextTestResult {
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

    private var asrLocalModelPathBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.asrConfig.localModelPath ?? defaultSenseVoiceModelPath },
            set: { providerSettingsStore.updateASRLocalModelPath($0) }
        )
    }

    private var textModelBinding: Binding<String> {
        Binding(
            get: { providerSettingsStore.textConfig.modelName },
            set: { providerSettingsStore.updateTextModel($0) }
        )
    }

    private var asrProviderOptions: [ProviderType] {
        ProviderType.allCases.filter(\.supportsTranscription)
    }

    private var textProviderOptions: [ProviderType] {
        ProviderType.allCases.filter(\.supportsRewrite)
    }

    private var pageContentMaxWidth: CGFloat {
        980
    }

    private var detailPaneBackground: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.06),
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0.96)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private func pageHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
        switch (providerSettingsStore.latestASRTestResult, providerSettingsStore.latestTextTestResult) {
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

    private var appVersionLine: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "-"
        return "\(shortVersion) (\(build))"
    }

    private func saveScenePolicy() {
        let appName = sceneAppNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = sceneBundleIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty, !bundleID.isEmpty else {
            settingsFeedback = "请先填写应用名和 Bundle ID。"
            return
        }

        appScenePolicyStore.upsertPolicy(
            appName: appName,
            bundleID: bundleID,
            outputBias: sceneOutputBiasDraft,
            preferSelectionRewrite: scenePreferRewriteDraft
        )
        settingsFeedback = "已保存 \(appName) 的策略。"
    }

    private func clearSceneDraft() {
        sceneAppNameDraft = ""
        sceneBundleIDDraft = ""
        sceneOutputBiasDraft = .neutral
        scenePreferRewriteDraft = true
    }

    private func loadSceneDraft(_ policy: AppScenePolicy) {
        sceneAppNameDraft = policy.appName
        sceneBundleIDDraft = policy.bundleID
        sceneOutputBiasDraft = policy.outputBias
        scenePreferRewriteDraft = policy.preferSelectionRewrite
        settingsFeedback = "已载入 \(policy.appName) 策略，可直接修改后保存。"
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

private struct SkillRuleCardView: View {
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    @Binding var parameter: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $isEnabled)
                    .labelsHidden()
            }

            TextField("参数", text: $parameter)
                .textFieldStyle(.roundedBorder)
                .disabled(!isEnabled)
        }
        .padding(12)
        .pulseCard(cornerRadius: 10)
    }
}

private struct ScenePolicyRowView: View {
    let policy: AppScenePolicy
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(policy.appName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("载入") {
                    onLoad()
                }
                .buttonStyle(.bordered)
                Button("删除", role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.bordered)
            }

            Text(policy.bundleID)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Label(policy.outputBias.displayName, systemImage: "textformat")
                    .font(.caption)
                Label(
                    policy.preferSelectionRewrite ? "优先改写" : "默认听写",
                    systemImage: policy.preferSelectionRewrite ? "wand.and.stars" : "mic"
                )
                .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .pulseCard(cornerRadius: 10)
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
        .pulseCard(cornerRadius: 10)
    }
}

private struct ModelConfigCard: View {
    let title: String
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
    let onSaveKey: () -> Bool
    let onDeleteKey: () -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .padding(.top, 2)

            Picker("Provider 类型", selection: providerType) {
                ForEach(availableProviderTypes) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.menu)

            if showsBaseURL {
                Text("API 地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(baseURLPlaceholder, text: baseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(!allowsCustomBaseURL)
            } else {
                Label("本地模式不需要接口地址。", systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("模型名")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(modelPlaceholder, text: modelName)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()

            if let localModelPath {
                Text("本地模型目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(defaultSenseVoiceModelPath, text: localModelPath)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }

            if showsAPIKey {
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
                    .disabled(credentialState == .missing || credentialState == .unknown)
                }
                .buttonStyle(.bordered)

                Label(
                    credentialStateTitle,
                    systemImage: credentialStateIcon
                )
                .font(.caption)
                .foregroundStyle(credentialStateColor)
            } else {
                Label("本地模型模式不需要 API 密钥。", systemImage: "lock.open.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private var credentialStateTitle: String {
        switch credentialState {
        case .saved:
            return "密钥已保存（钥匙串）"
        case .needsRebind:
            return "需要重绑：请重新保存一次密钥"
        case .unknown:
            return "密钥状态未检测"
        case .missing:
            return "密钥未保存"
        }
    }

    private var credentialStateIcon: String {
        switch credentialState {
        case .saved:
            return "lock.shield.fill"
        case .needsRebind:
            return "key.fill"
        case .unknown:
            return "questionmark.shield.fill"
        case .missing:
            return "exclamationmark.shield.fill"
        }
    }

    private var credentialStateColor: Color {
        switch credentialState {
        case .saved:
            return .secondary
        case .needsRebind:
            return .orange
        case .unknown:
            return .secondary
        case .missing:
            return .secondary
        }
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
        .pulseCard(cornerRadius: 8)
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

private struct PulseCardStyle: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape.fill(Color(nsColor: .controlBackgroundColor).opacity(0.95))
            )
            .overlay(
                shape.stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 7, x: 0, y: 2)
    }
}

private extension View {
    func pulseCard(cornerRadius: CGFloat) -> some View {
        modifier(PulseCardStyle(cornerRadius: cornerRadius))
    }
}
