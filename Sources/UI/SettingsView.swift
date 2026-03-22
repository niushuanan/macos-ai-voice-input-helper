import KeyboardShortcuts
import AppKit
import Combine
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    @ObservedObject private var controlCenterState: ControlCenterState
    @ObservedObject private var sessionStore: SessionStore
    @ObservedObject private var hotkeyStateStore: HotkeyStateStore
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager
    @ObservedObject private var skillRuleStore: SkillRuleStore
    @ObservedObject private var appScenePolicyStore: AppScenePolicyStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore
    @ObservedObject private var toastPresenter: ToastPresenter

    @State private var asrTesting = false
    @State private var textTesting = false
    @State private var memoryFeedback: String?
    @State private var sceneAppNameDraft = ""
    @State private var sceneBundleIDDraft = ""
    @State private var sceneOutputBiasDraft: AppOutputBias = .neutral
    @State private var sceneOriginalBundleID: String?
    @State private var isHydratingSceneDraft = false
    @State private var debouncedToastTask: Task<Void, Never>?
    @State private var debouncedSceneSaveTask: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        _controlCenterState = ObservedObject(wrappedValue: model.controlCenterState)
        _sessionStore = ObservedObject(wrappedValue: model.sessionStore)
        _hotkeyStateStore = ObservedObject(wrappedValue: model.hotkeyStateStore)
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _localSenseVoiceRuntimeManager = ObservedObject(wrappedValue: model.localSenseVoiceRuntimeManager)
        _skillRuleStore = ObservedObject(wrappedValue: model.skillRuleStore)
        _appScenePolicyStore = ObservedObject(wrappedValue: model.appScenePolicyStore)
        _localHistoryStore = ObservedObject(wrappedValue: model.localHistoryStore)
        _toastPresenter = ObservedObject(wrappedValue: model.toastPresenter)
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
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "首页",
                    subtitle: "主键开始语音，聆听中再次触发会停止并进入后续处理。"
                )

                HStack(spacing: 16) {
                    Label("主键：\(hotkeyStateStore.wakeShortcutText)", systemImage: "keyboard")
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
            .frame(maxWidth: .infinity, alignment: .leading)
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
                        ForEach(memoryFilters) { filter in
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
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onAppear {
            if controlCenterState.memoryFilter == .selectionRewrite {
                controlCenterState.memoryFilter = .all
            }
        }
    }

    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(
                    title: "Skill",
                    subtitle: "这里的偏好改完就会立刻生效。发生异常时会自动退回原始流程，不会卡住主链路。"
                )

                scenePolicySkillsCard

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
                    onTest: runASRTest
                )

                localSenseVoicePreparationCard

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
                    onTest: runTextTest
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

    private var localSenseVoicePreparationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地 SenseVoice")
                    .font(.headline)
                Text("实验")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Color.orange.opacity(0.15)))
                    .foregroundStyle(.orange)
                Spacer()
            }

            Text("只有本地运行环境准备完成后，ASR 列表里才会出现 SenseVoice。")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                Button("准备本地环境") {
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
        .padding(14)
        .pulseCard(cornerRadius: 12)
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
                    subtitle: "在这里管理快捷键、权限和基础信息。"
                )

                hotkeySettingsCard
                permissionSettingsCard
                aboutSettingsCard
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
    }

    private var hotkeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("快捷键")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("主键（开始/停止）")
                    .font(.subheadline.weight(.semibold))
                Picker(
                    "主键触发方式",
                    selection: Binding(
                        get: { hotkeyStateStore.wakeTriggerMode },
                        set: { mode in
                            hotkeyStateStore.setTriggerMode(mode, for: .wakeSession)
                            showToast("主键触发方式已改为\(mode.displayName)。")
                        }
                    )
                ) {
                    ForEach(HotkeyTriggerMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if hotkeyStateStore.wakeTriggerMode == .shortcut {
                    KeyboardShortcuts.Recorder("主键组合键", name: .wakeSession)
                } else {
                    Picker(
                        "主键修饰键",
                        selection: Binding(
                            get: { hotkeyStateStore.wakeModifier },
                            set: { modifier in
                                hotkeyStateStore.setModifier(modifier, for: .wakeSession)
                                showToast("主键已改为单击\(modifier.displayName)。")
                            }
                        )
                    ) {
                        ForEach(HotkeyModifier.allCases) { modifier in
                            Text(modifier.displayName).tag(modifier)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("当前主键：单击 \(hotkeyStateStore.wakeModifier.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("取消键")
                    .font(.subheadline.weight(.semibold))
                Picker(
                    "取消键触发方式",
                    selection: Binding(
                        get: { hotkeyStateStore.cancelTriggerMode },
                        set: { mode in
                            hotkeyStateStore.setTriggerMode(mode, for: .cancelSession)
                            showToast("取消键触发方式已改为\(mode.displayName)。")
                        }
                    )
                ) {
                    ForEach(HotkeyTriggerMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if hotkeyStateStore.cancelTriggerMode == .shortcut {
                    KeyboardShortcuts.Recorder("取消键组合键", name: .cancelSession)
                } else {
                    Picker(
                        "取消键修饰键",
                        selection: Binding(
                            get: { hotkeyStateStore.cancelModifier },
                            set: { modifier in
                                hotkeyStateStore.setModifier(modifier, for: .cancelSession)
                                showToast("取消键已改为单击\(modifier.displayName)。")
                            }
                        )
                    ) {
                        ForEach(HotkeyModifier.allCases) { modifier in
                            Text(modifier.displayName).tag(modifier)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("当前取消键：单击 \(hotkeyStateStore.cancelModifier.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("当前主键：\(hotkeyStateStore.wakeShortcutText)")
                Text("当前取消键：\(hotkeyStateStore.cancelShortcutText)")
                Text("最近更新：\(hotkeyStateStore.lastUpdatedAt.formatted(date: .omitted, time: .standard))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("检测主键监听") {
                    hotkeyStateStore.refresh()
                    showToast(hotkeyStateStore.registrationText(for: .wakeSession))
                }
                .buttonStyle(.bordered)

                Button("检测取消键监听") {
                    hotkeyStateStore.refresh()
                    showToast(hotkeyStateStore.registrationText(for: .cancelSession))
                }
                .buttonStyle(.bordered)
            }

            if let conflict = hotkeyStateStore.conflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("两个快捷键没有冲突，且会实时同步到监听器。", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            HStack {
                Button("恢复默认") {
                    hotkeyStateStore.resetToDefaults()
                    showToast("已恢复默认快捷键。")
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Text("快捷键监听：后台持续检测你设定的触发按键。主键用于开始/停止，取消键用于中断当前会话。")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            if permissionsCenter.runtimeDiagnostics.bundlePath != "/Applications/PulseType.app" {
                Label(
                    "当前不是 /Applications/PulseType.app。建议用安装脚本覆盖到 /Applications，避免权限反复重置。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("当前运行实例")
                    .font(.subheadline.weight(.semibold))
                Text("Bundle ID：\(permissionsCenter.runtimeDiagnostics.bundleIdentifier)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Text("可执行文件：\(permissionsCenter.runtimeDiagnostics.executablePath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("签名摘要：\(permissionsCenter.runtimeDiagnostics.signatureSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("最近检测：\(permissionsCenter.runtimeDiagnostics.checkedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Label("系统设置里如出现多个 PulseType，请只保留这一路径对应的项。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text("把应用风格总开关和策略编辑放在一起。这里的改动会自动保存并立刻生效。")
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
            }

            Text("应用名和 Bundle ID 填完整后会自动保存。这里的策略只作用于普通听写。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("读取当前应用") {
                    fillSceneDraftWithCurrentApp()
                }
                .buttonStyle(.bordered)
                Spacer()
            }

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

            HStack {
                Button("新建空白策略") {
                    clearSceneDraft()
                    showToast("可以直接新建一条应用风格策略了。")
                }
                .buttonStyle(.bordered)

                Spacer()
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
                            if sceneOriginalBundleID == policy.bundleID {
                                clearSceneDraft()
                            }
                            showToast("已删除 \(policy.appName) 的策略。")
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
        .onChange(of: sceneAppNameDraft) { _, _ in
            scheduleScenePolicyAutosave()
        }
        .onChange(of: sceneBundleIDDraft) { _, _ in
            scheduleScenePolicyAutosave()
        }
        .onChange(of: sceneOutputBiasDraft) { _, _ in
            scheduleScenePolicyAutosave()
        }
    }

    private var aboutSettingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("关于")
                .font(.headline)

            LabeledContent("应用名", value: "PulseType")
            LabeledContent("版本", value: appVersionLine)
            LabeledContent("产品定位", value: "macOS 桌面语音输入助手")
            LabeledContent("数据策略", value: "历史、配置、诊断默认保存在本地")
            LabeledContent("密钥策略", value: "API Key 仅在本地应用目录保存（不再触发钥匙串弹窗）")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
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

    private var textProviderTypeBinding: Binding<ProviderType> {
        Binding(
            get: { providerSettingsStore.textConfig.providerType },
            set: {
                providerSettingsStore.updateTextProviderType($0)
                showToast("文本处理服务商已切换，现在已经生效。")
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

    private var asrProviderOptions: [ProviderType] {
        ProviderType.allCases.filter { type in
            guard type.supportsTranscription else {
                return false
            }
            if type != .localSenseVoice {
                return true
            }
            if providerSettingsStore.asrConfig.providerType == .localSenseVoice {
                return true
            }
            if case .ready = localSenseVoiceRuntimeManager.state {
                return true
            }
            return false
        }
    }

    private var textProviderOptions: [ProviderType] {
        ProviderType.allCases.filter(\.supportsRewrite)
    }

    private var detailPaneBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.white.opacity(0.72),
                Color.accentColor.opacity(0.05)
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

    private var isPreparingLocalSenseVoice: Bool {
        if case .preparing = localSenseVoiceRuntimeManager.state {
            return true
        }
        return false
    }

    private var primaryToggleTitle: String {
        sessionStore.phase == .listening ? "停止并处理" : "开始语音输入"
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

    private var memoryFilters: [LocalHistoryFilter] {
        LocalHistoryFilter.allCases.filter { $0 != .selectionRewrite }
    }

    private func clearSceneDraft() {
        debouncedSceneSaveTask?.cancel()
        sceneAppNameDraft = ""
        sceneBundleIDDraft = ""
        sceneOutputBiasDraft = .neutral
        sceneOriginalBundleID = nil
    }

    private func loadSceneDraft(_ policy: AppScenePolicy) {
        isHydratingSceneDraft = true
        sceneAppNameDraft = policy.appName
        sceneBundleIDDraft = policy.bundleID
        sceneOutputBiasDraft = policy.outputBias
        sceneOriginalBundleID = policy.bundleID
        DispatchQueue.main.async {
            isHydratingSceneDraft = false
        }
        showToast("已载入 \(policy.appName) 的策略。")
    }

    private func scheduleScenePolicyAutosave() {
        guard !isHydratingSceneDraft else {
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
        let appName = sceneAppNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleID = sceneBundleIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appName.isEmpty, !bundleID.isEmpty else {
            return
        }

        if
            let originalBundleID = sceneOriginalBundleID,
            originalBundleID != bundleID
        {
            appScenePolicyStore.removePolicy(bundleID: originalBundleID)
        }

        appScenePolicyStore.upsertPolicy(
            appName: appName,
            bundleID: bundleID,
            outputBias: sceneOutputBiasDraft,
            preferSelectionRewrite: false
        )
        sceneOriginalBundleID = bundleID
        showToast("\(appName) 的应用风格已更新并生效。")
    }

    private func fillSceneDraftWithCurrentApp() {
        let context = model.contextDetector.focusedAppContext()
        guard context.bundleID != Bundle.main.bundleIdentifier else {
            showToast("请先把焦点切到目标应用的输入框，再读取。")
            return
        }
        isHydratingSceneDraft = true
        sceneAppNameDraft = context.appName
        sceneBundleIDDraft = context.bundleID
        DispatchQueue.main.async {
            isHydratingSceneDraft = false
        }
        scheduleScenePolicyAutosave()
        showToast("已读取当前应用：\(context.appName)。")
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
                if let outputPathTitle {
                    Label(outputPathTitle, systemImage: outputPathSymbol)
                        .font(.caption2)
                        .foregroundStyle(outputPathColor)
                }
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
            return "text.cursor"
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

private struct SkillRuleCardView: View {
    let ruleID: SkillRuleID
    let title: String
    let subtitle: String
    @Binding var isEnabled: Bool
    @Binding var parameter: String
    let parameterPlaceholder: String

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

            if ruleID == .systemPrompt {
                TextEditor(text: $parameter)
                    .font(.system(size: 13))
                    .frame(minHeight: 84, maxHeight: 120)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                    )
                    .disabled(!isEnabled)
            } else {
                TextField(parameterPlaceholder, text: $parameter)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isEnabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    "普通听写",
                    systemImage: "mic"
                )
                .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PulseToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
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
    let onSaveKey: () -> Void
    let onDeleteKey: () -> Void

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
            return .secondary
        case .saved:
            return .secondary
        case .inaccessible:
            return .orange
        case .failed:
            return .red
        case .unknown:
            return .secondary
        case .missing:
            return .secondary
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
                shape.fill(Color.white.opacity(0.82))
                    .background(
                        shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
                    )
                    .background(
                        shape.fill(.ultraThinMaterial).opacity(0.55)
                    )
            )
            .overlay(
                shape.stroke(Color.white.opacity(0.86), lineWidth: 1)
                    .shadow(color: Color.black.opacity(0.045), radius: 0, x: 0, y: 0)
            )
            .shadow(color: Color.black.opacity(0.055), radius: 14, x: 0, y: 4)
    }
}

private extension View {
    func pulseCard(cornerRadius: CGFloat) -> some View {
        modifier(PulseCardStyle(cornerRadius: cornerRadius))
    }
}
