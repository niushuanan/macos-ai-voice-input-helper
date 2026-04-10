import AppKit
import Combine
import EventKit
import KeyboardShortcuts
import SwiftUI
import UserNotifications

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
    @State private var magicianComposeEmailAvailable = MagicianMailCapability.composeEmailServiceAvailable
    @State private var magicianMailtoAvailable = MagicianMailCapability.mailtoAvailable
    @State private var magicianMailAppAvailable = MagicianMailCapability.mailAppAvailable
    @State private var magicianMusicAppAvailable = MagicianMusicCapability.musicAppAvailable
    @State private var magicianNotificationAuthorizationStatus: V4NotificationAuthorizationStatus = .notDetermined
    @State private var magicianClockAppAvailable = MagicianClockCapability.clockAppAvailable
    @State private var magicianClockAlarmSurfaceAvailable = MagicianClockCapability.canOpen(surface: .alarm)
    @State private var magicianClockTimerSurfaceAvailable = MagicianClockCapability.canOpen(surface: .timer)
    @State private var localSenseVoiceDetailsExpanded = false
    @State private var developerEntryExpanded = false
    @State private var memoryToolbarAvailableWidth: CGFloat = 0
    @State private var memoryFilterBarWidth: CGFloat = 0
    @State private var clearMemoryButtonWidth: CGFloat = 0
    @State private var timeMachineItems: [V4TimeItem] = []

    private let magicianStatusResolver = MagicianStatusResolver()

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
                    .font(PulseUI.Typography.bodyStrong)
                    .lineSpacing(PulseUI.Typography.bodyLineSpacing)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(.clear)
            .environment(\.defaultMinListRowHeight, 26)
            .navigationSplitViewColumnWidth(min: 208, ideal: 224, max: 244)
            .navigationTitle("PulseType")
        } detail: {
            ZStack {
                detailPaneBackground
                    .ignoresSafeArea()

                detailPaneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                if let toast = toastPresenter.message {
                    VStack {
                        Spacer()
                        PulseToastView(text: toast.text)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 20)
                    }
                    .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
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
            }
            if section == .agentBrainstorm {
                hotkeyStateStore.refresh()
                model.interactionCoordinator.ensureBrainstormDurationProfile()
            }
            if section == .timeMachine {
                refreshTimeMachineItems()
            }
            if section == .magician {
                refreshMagicianCapabilityState()
                permissionsCenter.refreshStatuses()
            }
            if section != .agentBrainstorm, brainstormModifierCaptureState != nil {
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

    @ViewBuilder
    private var detailPaneContent: some View {
        selectedDetailPage
    }

    @ViewBuilder
    private var selectedDetailPage: some View {
        switch controlCenterState.selectedSection {
        case .home:
            homePage
        case .memory:
            memoryPage
        case .magician:
            magicianPage
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

    private func pageTitleText(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(PulseUI.Typography.pageTitle)
                .tracking(0.16)
                .lineSpacing(PulseUI.Typography.pageTitleLineSpacing)
                .pulsePrimaryText()

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(PulseUI.Typography.caption)
                    .lineSpacing(PulseUI.Typography.captionLineSpacing)
                    .pulseSecondaryText()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitleText("首页", subtitle: "先说，再写。你常用的数据和入口都在这里。")

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
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.top, 10)
            .padding(.bottom, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            permissionsCenter.refreshStatuses()
        }
    }

    private var memoryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageTitleText("历史", subtitle: "这里保存你的会话结果。可以删单条，也可以一次清理历史数据。")

                memoryToolbar

                if filteredHistoryEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("当前筛选下还没有记录。", systemImage: "tray")
                            .font(PulseUI.Typography.bodyStrong)
                        Text("先回首页进行一次语音会话，完成后就会出现记录。")
                            .font(PulseUI.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .controlCenterSectionGroup()
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredHistoryEntries) { entry in
                            MemoryRowView(
                                entry: entry,
                                onCopyPrimary: { copyPrimaryMemoryText(entry) },
                                onCopyDialogue: { copyBrainstormDialogueText(entry) },
                                onCopyRaw: { copyRawMemoryText(entry) },
                                onCopyCommand: { copyInstructionMemoryText(entry) },
                                onCopyExecutionInterpretation: { copyExecutionInterpretationMemoryText(entry) },
                                onCopyExecutionTrace: { copyExecutionTraceMemoryText(entry) },
                                onDelete: {
                                    localHistoryStore.delete(entryID: entry.id)
                                    showToast("已删除一条记录。")
                                }
                            )
                            .padding(12)
                            .controlCenterListRow()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
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
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText("魔术先生", subtitle: "长按主键说一句，松开后立刻执行。这里查看每个动作是否就绪。")

                magicianTextTransformSection
                magicianNativeActionsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            refreshMagicianCapabilityState()
            permissionsCenter.refreshStatuses()
        }
    }

    private var magicianTextTransformSection: some View {
        magicianFeatureSection(
            title: "文本处理",
            subtitle: "直接处理当前选中文本。",
            features: [.textTransform]
        )
    }

    private var magicianNativeActionsSection: some View {
        magicianFeatureSection(
            title: "原生动作",
            subtitle: "日历、文档、邮件、音乐、时钟等系统动作。",
            features: [.calendar, .markdownDocument, .mail, .music, .clock]
        )
    }

    private func magicianFeatureSection(
        title: String,
        subtitle: String,
        features: [MagicianFeatureID]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PulseUI.Typography.sectionTitle)
                Text(subtitle)
                    .font(PulseUI.Typography.body)
                    .foregroundStyle(.primary.opacity(0.84))
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(features.enumerated()), id: \.element.rawValue) { index, feature in
                    magicianFeatureRow(feature: feature)
                    if index < features.count - 1 {
                        Divider()
                            .padding(.leading, 44)
                    }
                }
            }
            .padding(16)
            .controlCenterSectionGroup()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func magicianFeatureRow(feature: MagicianFeatureID) -> some View {
        let resolution = magicianStatusResolver.resolve(
            feature: feature,
            isEnabled: magicianFeatureToggleStore.isEnabled(feature),
            dependencies: currentMagicianDependencies
        )

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: feature.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(feature.displayName)
                        .font(PulseUI.Typography.bodyStrong)
                    Text(feature.summaryLine)
                        .font(PulseUI.Typography.body)
                        .lineSpacing(PulseUI.Typography.bodyLineSpacing)
                        .foregroundStyle(.primary.opacity(0.84))
                    Text(feature.boundaryLine)
                        .font(PulseUI.Typography.caption)
                        .lineSpacing(PulseUI.Typography.captionLineSpacing)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Toggle("", isOn: magicianFeatureToggleBinding(feature))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle())
                    .scaleEffect(0.8)
                    .fixedSize()
                    .disabled(magicianFeatureToggleDisabled(resolution))
            }

            if let reason = resolution.reason {
                Label(reason, systemImage: magicianGateHintIcon(resolution.gateKind))
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if let prompt = resolution.prompt {
                HStack(spacing: 8) {
                    magicianFeaturePromptButton(prompt: prompt, gateKind: resolution.gateKind)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }

    private func magicianFeatureToggleBinding(_ feature: MagicianFeatureID) -> Binding<Bool> {
        Binding(
            get: { magicianFeatureToggleStore.isEnabled(feature) },
            set: { enabled in
                handleMagicianFeatureToggleChange(feature: feature, enabled: enabled)
            }
        )
    }

    private func magicianFeatureToggleDisabled(_ resolution: MagicianFeatureStatusResolution) -> Bool {
        resolution.availability == .blocked && resolution.status == .notEnabled
    }

    private func magicianGateHintIcon(_ gateKind: MagicianFeatureGateKind) -> String {
        switch gateKind {
        case .systemPermission:
            return "lock.shield"
        case .serviceDependency:
            return "app.badge"
        case .modelDependency:
            return "cpu"
        case .ready:
            return "info.circle"
        }
    }

    @ViewBuilder
    private func magicianFeaturePromptButton(
        prompt: MagicianPermissionPromptModel,
        gateKind: MagicianFeatureGateKind
    ) -> some View {
        if gateKind == .systemPermission {
            Button(prompt.primaryButtonTitle) {
                handleMagicianPromptPrimary(prompt)
            }
            .controlCenterPrimaryActionButton()
            .controlSize(.small)
        } else {
            Button(prompt.primaryButtonTitle) {
                handleMagicianPromptPrimary(prompt)
            }
            .controlCenterSecondaryActionButton()
            .controlSize(.small)
        }
    }

    private var modelPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitleText("引擎", subtitle: "语音、文本和 CLI 三个能力槽。修改后会立即生效。")

                modelRoleSection(
                    roleTitle: "语音识别",
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
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
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
                pageTitleText("词典", subtitle: "每行一个词，支持术语和短语，保存后立刻生效。")

                VStack(alignment: .leading, spacing: 10) {
                    Text("词典内容")
                        .font(PulseUI.Typography.sectionTitle)

                    TextEditor(text: $dictionaryDraft)
                        .font(PulseUI.Typography.caption)
                        .frame(minHeight: 220, maxHeight: 320)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: PulseUI.Radius.card, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                .background(
                                    RoundedRectangle(cornerRadius: PulseUI.Radius.card, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                )
                        )

                    HStack(alignment: .center, spacing: 12) {
                        Button("保存") {
                            saveDictionary()
                        }
                        .controlCenterPrimaryActionButton()

                        Text(dictionaryStatusLine)
                            .font(PulseUI.Typography.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .controlCenterSectionGroup()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            dictionaryDraft = asrDictionaryStore.rawText
        }
    }

    private func modelRoleSection(
        roleTitle: String,
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
        let providerTitle = providerType.wrappedValue.displayName
        let modelTitle = modelName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "模型未设置"
            : modelName.wrappedValue
        let roleStatusTitle: String = if isTesting {
            "测试中"
        } else if let latestResult {
            latestResult.status == .success ? "成功" : "失败"
        } else {
            "未测试"
        }
        let roleStatusIcon: String = if isTesting {
            "hourglass"
        } else if let latestResult {
            latestResult.status == .success ? "checkmark.circle.fill" : "xmark.octagon.fill"
        } else {
            "clock"
        }
        let roleStatusTint: Color = if isTesting {
            PulseUI.ColorTokens.textSecondary
        } else if let latestResult {
            latestResult.status == .success ? PulseUI.ColorTokens.success : PulseUI.ColorTokens.danger
        } else {
            PulseUI.ColorTokens.textSecondary
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(roleTitle)
                        .font(PulseUI.Typography.sectionTitle)
                        .pulsePrimaryText()
                    Text("当前：\(providerTitle) · \(modelTitle)")
                        .font(PulseUI.Typography.caption)
                        .lineSpacing(PulseUI.Typography.captionLineSpacing)
                        .pulseSecondaryText()
                        .lineLimit(1)
                }

                Spacer()

                ControlCenterStatusPill(
                    title: roleStatusTitle,
                    systemImage: roleStatusIcon,
                    tint: roleStatusTint
                )

                Button(isTesting ? "\(testButtonTitle)中..." : testButtonTitle) {
                    onTest()
                }
                .controlCenterPrimaryActionButton()
                .controlSize(.small)
                .disabled(isTesting)
            }

            ModelStatusPanel(
                activeConfigLine: activeConfigLine,
                latestResult: latestResult,
                isTesting: isTesting,
                failureSuggestion: latestResult.flatMap { result in
                    result.status == .failure ? actionSuggestion(for: result) : nil
                }
            )

            ModelConfigCard(
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
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var localSenseVoiceRuntimeInlineSection: some View {
        DisclosureGroup("本地运行信息", isExpanded: $localSenseVoiceDetailsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
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
                .font(PulseUI.Typography.body)

                HStack {
                    Button("准备环境") {
                        Task {
                            await localSenseVoiceRuntimeManager.prepare(
                                modelDirectoryPath: providerSettingsStore.asrConfig.localModelPath
                            )
                        }
                    }
                    .controlCenterPrimaryActionButton()
                    .controlSize(.small)
                    .disabled(isPreparingLocalSenseVoice)

                    Button("重新检测") {
                        Task {
                            await localSenseVoiceRuntimeManager.detect(
                                modelDirectoryPath: providerSettingsStore.asrConfig.localModelPath
                            )
                        }
                    }
                    .controlCenterSecondaryActionButton()
                    .controlSize(.small)
                    .disabled(isPreparingLocalSenseVoice)

                    Spacer()
                }
            }
            .padding(.top, 8)
        }
        .font(PulseUI.Typography.bodyStrong)
        .padding(10)
        .controlCenterInsetPanel(cornerRadius: PulseUI.Radius.card)
    }

    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText("设置", subtitle: "管理快捷键、权限与基础行为。")

                expressionPreferenceCard
                scenePolicySkillsCard
                hotkeySettingsCard
                permissionSettingsCard
                developerEntryCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
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
            VStack(alignment: .leading, spacing: 16) {
                pageTitleText("讨论整理", subtitle: "适合短时讨论，结束后自动整理成可直接使用的上下文。")

                brainstormIntroCard
                brainstormTriggerCard
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
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
                .font(PulseUI.Typography.sectionTitle)
            Label("多人聊完一个想法后，可直接生成能发给 AI 的上下文。", systemImage: "person.2")
                .font(PulseUI.Typography.body)
            Label("自动理清讨论重点，减少你手动补背景。", systemImage: "text.bubble")
                .font(PulseUI.Typography.body)
            Label("整理结果会放进输入框和剪贴板，下一问马上接上。", systemImage: "doc.on.clipboard")
                .font(PulseUI.Typography.body)
            Divider()
            Text("当前模型实测上限：\(profile.maxSeconds) 秒")
                .font(PulseUI.Typography.body)
                .foregroundStyle(.primary.opacity(0.84))
            Text("推荐时长：\(profile.recommendedSeconds) 秒以内")
                .font(PulseUI.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var brainstormTriggerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("触发层")
                .font(PulseUI.Typography.sectionTitle)

            brainstormModifierSection(
                title: "双击修饰键",
                currentText: "当前触发：双击 \(hotkeyStateStore.brainstormModifier.displayName)"
            )

            if let conflict = hotkeyStateStore.conflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("触发配置可用。", systemImage: "checkmark.circle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .controlCenterSectionGroup()
    }

    private func brainstormModifierSection(
        title: String,
        currentText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(PulseUI.Typography.bodyStrong)
            ModifierCaptureButton(
                valueText: brainstormModifierCaptureState?.pendingModifier?.displayName ?? hotkeyStateStore.brainstormModifier.displayName,
                isCapturing: brainstormModifierCaptureState != nil,
                action: startBrainstormModifierCapture
            )

            if let brainstormCaptureHint = brainstormModifierCaptureState?.hint {
                Text(brainstormCaptureHint)
                    .font(PulseUI.Typography.monospacedMeta)
                    .foregroundStyle(.secondary)
            } else {
                Text("点击上面的括号区域后，按左/右修饰键，再按 Enter 确认，按 Esc 取消。")
                    .font(PulseUI.Typography.monospacedMeta)
                    .foregroundStyle(.secondary)
            }

            Text(currentText)
                .font(PulseUI.Typography.body)
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    private var hotkeySettingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快捷键")
                .font(PulseUI.Typography.sectionTitle)

            VStack(alignment: .leading, spacing: 8) {
                Text("主键（开始/停止）")
                    .font(PulseUI.Typography.bodyStrong)
                VStack(alignment: .leading, spacing: 8) {
                    Text("单键触发按键")
                        .font(PulseUI.Typography.bodyStrong)
                        .foregroundStyle(.primary)

                    ModifierCaptureButton(
                        valueText: wakeModifierCaptureState?.pendingModifier?.displayName ?? hotkeyStateStore.wakeModifier.displayName,
                        isCapturing: wakeModifierCaptureState != nil,
                        action: startWakeModifierCapture
                    )

                    if let wakeModifierCaptureHint = wakeModifierCaptureState?.hint {
                        Text(wakeModifierCaptureHint)
                            .font(PulseUI.Typography.monospacedMeta)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("点击上面的括号区域后，按左/右修饰键，再按 Enter 确认，按 Esc 取消。")
                            .font(PulseUI.Typography.monospacedMeta)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("当前主键：单键触发 · \(hotkeyStateStore.wakeModifier.displayName)")
                    .font(PulseUI.Typography.body)
                    .foregroundStyle(.primary.opacity(0.8))
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("取消键")
                    .font(PulseUI.Typography.bodyStrong)
                Text("取消键固定为 Esc，不支持修改。")
                    .font(PulseUI.Typography.body)
                    .foregroundStyle(.primary.opacity(0.84))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("触发规则说明")
                    .font(PulseUI.Typography.bodyStrong)
                Text("单击开始或停止普通语音，长按进入魔术先生，双击进入一口气全念对。")
                    .font(PulseUI.Typography.body)
                    .foregroundStyle(.primary.opacity(0.84))
                if hotkeyStateStore.wakeModifier == hotkeyStateStore.brainstormModifier {
                    Text("当前两者共用同一按键：双击优先一口气全念对，长按优先魔术先生。")
                        .font(PulseUI.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let conflict = hotkeyStateStore.conflictMessage {
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.orange)
            } else {
                Label("两个快捷键没有冲突。", systemImage: "checkmark.circle.fill")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var permissionSettingsCard: some View {
        let items = permissionsCenter.presentationItems()

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("权限中心")
                        .font(PulseUI.Typography.sectionTitle)
                    Text("麦克风负责录音，辅助功能负责读取选区和直写。")
                        .font(PulseUI.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("重新检测") {
                    permissionsCenter.refreshStatuses()
                }
                .controlCenterSecondaryActionButton()
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    PermissionRowView(
                        item: item,
                        onRequest: { permissionsCenter.requestAccess(for: item.id) },
                        onOpenSettings: { permissionsCenter.openSystemSettings(for: item.id) }
                    )
                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }

            if permissionsCenter.runtimeDiagnostics.bundlePath != runtimePolicy.installPath {
                Label(
                    "当前不是 \(runtimePolicy.installPath)。建议用安装脚本覆盖到 \(runtimePolicy.installURL.deletingLastPathComponent().path)，避免权限反复重置。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(PulseUI.Typography.caption)
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var developerEntryCard: some View {
        DisclosureGroup("开发者文档与诊断（可选）", isExpanded: $developerEntryExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("普通使用不需要这一块。只有在排查问题或做高级配置时再打开。")
                    .font(PulseUI.Typography.caption)
                    .lineSpacing(PulseUI.Typography.captionLineSpacing)
                    .pulseSecondaryText()

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("运行目录", value: model.localStore.rootDirectory.path)
                    LabeledContent("当前 App", value: Bundle.main.bundleURL.path)
                }
                .font(PulseUI.Typography.caption)
                .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button("打开运行目录") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.localStore.rootDirectory])
                    }
                    .controlCenterSecondaryActionButton()
                    .controlSize(.small)

                    Button("打开 App 包") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    .controlCenterSecondaryActionButton()
                    .controlSize(.small)

                    Button("打开前端设计规范") {
                        let url = model.localStore.rootDirectory
                            .appendingPathComponent("docs", isDirectory: true)
                            .appendingPathComponent("pulse-frontend-design-library-v2.md")
                        NSWorkspace.shared.open(url)
                    }
                    .controlCenterSecondaryActionButton()
                    .controlSize(.small)
                }
            }
            .padding(.top, 8)
        }
        .font(PulseUI.Typography.bodyStrong)
        .padding(12)
        .controlCenterSectionGroup()
    }

    private var expressionPreferenceCard: some View {
        let visibleRules = skillRuleStore.visibleRules()

        return VStack(alignment: .leading, spacing: 12) {
            Text("表达偏好")
                .font(PulseUI.Typography.sectionTitle)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visibleRules.enumerated()), id: \.element.id) { index, rule in
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
                            ? "例如：默认更直接、少一点客套、保留重点"
                            : "例如：嗯,啊,就是,那个,然后"
                    )
                    if index < visibleRules.count - 1 {
                        Divider()
                            .padding(.leading, 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .controlCenterSectionGroup()
    }

    private var scenePolicySkillsCard: some View {
        let normalizedQuery = sceneSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let appMatches = filteredDiscoveredApps

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按应用风格")
                        .font(PulseUI.Typography.sectionTitle)
                    Text("给常用应用单独定语气，聊天、邮件、文档可以各说各的话。")
                        .font(PulseUI.Typography.body)
                        .foregroundStyle(.primary.opacity(0.84))
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
                .font(PulseUI.Typography.caption)
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
                        .font(PulseUI.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !appMatches.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(appMatches.prefix(8))) { app in
                        SceneAppCandidateRowView(
                            app: app,
                            onAdd: {
                                addScenePolicy(from: app)
                            }
                        )
                    }
                }
            } else if !normalizedQuery.isEmpty {
                Text("没有匹配结果，请换个关键词。")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if sortedScenePolicies.isEmpty {
                Text("还没有策略。先在上面搜索应用并添加。")
                    .font(PulseUI.Typography.caption)
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
                        .font(PulseUI.Typography.bodyStrong)
                    Text(editingPolicy.bundleID)
                        .font(PulseUI.Typography.monospacedMeta)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $scenePromptDraft)
                        .font(PulseUI.Typography.caption)
                        .frame(minHeight: 88, maxHeight: 130)
                        .padding(6)
                        .controlCenterInsetPanel()
                    HStack {
                        Button("完成编辑") {
                            autoSaveScenePolicyIfPossible()
                            sceneEditingBundleID = nil
                            sceneEditingAppName = ""
                        }
                        .controlCenterSecondaryActionButton()
                        Spacer()
                    }
                }
            } else {
                Text("点“编辑”后即可输入该应用专属提示词，保存会自动生效。")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .controlCenterSectionGroup()
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
                .font(PulseUI.Typography.sectionTitle)

            Label("开口就写，直接出稿：不用切输入法，不用先找输入框。", systemImage: "text.bubble")
                .font(PulseUI.Typography.body)
            Label("一口气全念对：连续口述也能变成通顺文本，讲完就是成稿。", systemImage: "brain.head.profile")
                .font(PulseUI.Typography.body)
            Label("魔术先生主打执行：一句话就能改写、翻译、整理，并直接完成动作。", systemImage: "wand.and.stars")
                .font(PulseUI.Typography.body)
            Label("模型自由切换：云端 API 和本地模型都能接，按速度、效果、隐私随时换。", systemImage: "square.grid.2x2")
                .font(PulseUI.Typography.body)
            Label("时光机负责记忆和提醒：灵感不丢，关键时间点不会漏。", systemImage: "clock.badge.exclamationmark")
                .font(PulseUI.Typography.body)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: PulseUI.Radius.sectionGroup)
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
        ControlCenterDetailBackground()
    }

    private var magicianTextModelReady: Bool {
        providerSettingsStore.textConfigurationValidationMessage == nil
            && {
                if !providerSettingsStore.textConfig.providerType.requiresAPIKey {
                    return true
                }
                switch providerSettingsStore.textCredentialState {
                case .saved, .inaccessible:
                    return true
                case .saving, .failed, .unknown, .missing:
                    return false
                }
            }()
    }

    private var currentMagicianDependencies: MagicianDependencySnapshot {
        MagicianDependencySnapshot(
            accessibilityState: permissionsCenter.snapshot.accessibility,
            textModelReady: magicianTextModelReady,
            eventAuthorizationStatus: magicianEventAuthorizationStatus,
            composeEmailAvailable: magicianComposeEmailAvailable,
            mailtoAvailable: magicianMailtoAvailable,
            mailAppAvailable: magicianMailAppAvailable,
            musicAppAvailable: magicianMusicAppAvailable,
            notificationAuthorizationStatus: magicianNotificationAuthorizationStatus,
            clockAppAvailable: magicianClockAppAvailable,
            clockAlarmSurfaceAvailable: magicianClockAlarmSurfaceAvailable,
            clockTimerSurfaceAvailable: magicianClockTimerSurfaceAvailable
        )
    }

    private func refreshMagicianCapabilityState() {
        magicianEventAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
        magicianComposeEmailAvailable = MagicianMailCapability.composeEmailServiceAvailable
        magicianMailtoAvailable = MagicianMailCapability.mailtoAvailable
        magicianMailAppAvailable = MagicianMailCapability.mailAppAvailable
        magicianMusicAppAvailable = MagicianMusicCapability.musicAppAvailable
        magicianClockAppAvailable = MagicianClockCapability.clockAppAvailable
        magicianClockAlarmSurfaceAvailable = MagicianClockCapability.canOpen(surface: .alarm)
        magicianClockTimerSurfaceAvailable = MagicianClockCapability.canOpen(surface: .timer)

        Task {
            let notificationCenter = V4UNUserNotificationCenterClient()
            let notificationStatus = await notificationCenter.authorizationStatus()
            await MainActor.run {
                magicianNotificationAuthorizationStatus = notificationStatus
            }
        }
    }

    private func handleMagicianFeatureToggleChange(
        feature: MagicianFeatureID,
        enabled: Bool
    ) {
        guard enabled else {
            magicianFeatureToggleStore.setEnabled(false, for: feature)
            showToast("\(feature.displayName)已关闭。")
            return
        }

        let requirement = magicianStatusResolver.requirement(
            for: feature,
            dependencies: currentMagicianDependencies
        )
        switch requirement {
        case .ready:
            magicianFeatureToggleStore.setEnabled(true, for: feature)
            showToast("\(feature.displayName)已开启。")
        case let .blocked(_, _, prompt):
            magicianFeatureToggleStore.setEnabled(false, for: feature)
            magicianPermissionPrompt = prompt
        }
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
                case let .blocked(_, reason, _):
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
        case .requestNotificationAccess:
            _ = try? await V4UNUserNotificationCenterClient().requestAuthorization()
        case let .openSettingsSection(sectionID):
            await MainActor.run {
                switch sectionID {
                case "model":
                    controlCenterState.selectedSection = .model
                case "settings":
                    controlCenterState.selectedSection = .settings
                default:
                    break
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
        case let .openClockApp(surface):
            await MainActor.run {
                openClockSurface(surface)
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

    private func openClockSurface(_ surface: MagicianClockSurface?) {
        if
            let surface,
            let surfaceURL = URL(string: surface.urlString),
            NSWorkspace.shared.urlForApplication(toOpen: surfaceURL) != nil
        {
            NSWorkspace.shared.open(surfaceURL)
            return
        }

        openApplication(
            bundleIdentifier: MagicianClockCapability.bundleIdentifier,
            fallbackPath: MagicianClockCapability.appPath
        )
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
        return ConnectionFailureAdvisor.suggestion(for: result)
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
        .controlCenterSecondaryActionButton()
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
                pageTitleText("时光机", subtitle: "提醒与时间中心。默认走本地通知，必要时再跳转系统时钟。")

                timeMachineOverviewCard

                if timeMachineItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("当前还没有时光机记录。", systemImage: "clock.badge.questionmark")
                            .font(PulseUI.Typography.bodyStrong)
                        Text("你可以对魔术先生说“30 分钟后提醒我…”或“记一下…”。")
                            .font(PulseUI.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .controlCenterSectionGroup()
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(timeMachineItems.prefix(120)) { item in
                            timeMachineRow(item)
                                .padding(12)
                                .controlCenterListRow()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PulseUI.Spacing.pageHorizontal)
            .padding(.vertical, PulseUI.Spacing.pageVertical)
        }
        .onAppear {
            refreshMagicianCapabilityState()
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
                .font(PulseUI.Typography.sectionTitle)
            HStack(spacing: 12) {
                Label("总记录 \(total)", systemImage: "tray.full")
                    .font(PulseUI.Typography.caption)
                Label("已定时 \(scheduled)", systemImage: "checkmark.circle")
                    .font(PulseUI.Typography.caption)
                Label("失败 \(failed)", systemImage: "exclamationmark.triangle")
                    .font(PulseUI.Typography.caption)
            }
            if let latest {
                Text("最近写入：\(latest.formatted(date: .abbreviated, time: .shortened))")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Text("提醒状态：\(notificationReadinessText)")
                .font(PulseUI.Typography.caption)
                .foregroundStyle(.secondary)
            Text("Clock 入口：\(clockHandoffReadinessText)")
                .font(PulseUI.Typography.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("刷新时光机") {
                    refreshTimeMachineItems()
                    showToast("时光机列表已刷新。")
                }
                .controlCenterSecondaryActionButton()

                Button("打开时钟") {
                    openClockSurface(.worldClock)
                }
                .controlCenterSecondaryActionButton()
                .disabled(!magicianClockAppAvailable)

                Button("闹钟") {
                    openClockSurface(.alarm)
                }
                .controlCenterSecondaryActionButton()
                .disabled(!magicianClockAlarmSurfaceAvailable && !magicianClockAppAvailable)

                Button("计时器") {
                    openClockSurface(.timer)
                }
                .controlCenterSecondaryActionButton()
                .disabled(!magicianClockTimerSurfaceAvailable && !magicianClockAppAvailable)

                Spacer()
            }
        }
        .padding(16)
        .controlCenterSectionGroup()
    }

    private func timeMachineRow(_ item: V4TimeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(item.normalizedText.isEmpty ? item.rawCommand : item.normalizedText)
                    .font(PulseUI.Typography.sectionTitle)
                Spacer()
                Text(timeMachineStatusText(item.status))
                    .font(PulseUI.Typography.captionStrong)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(timeMachineStatusColor(item.status).opacity(0.16))
                    )
                    .foregroundStyle(timeMachineStatusColor(item.status))
            }

            Text("创建时间：\(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(PulseUI.Typography.caption)
                .foregroundStyle(.secondary)

            if let scheduledAt = item.scheduledAt {
                Text("提醒时间：\(scheduledAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(PulseUI.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if !item.tags.isEmpty {
                Text("标签：\(item.tags.joined(separator: " · "))")
                    .font(PulseUI.Typography.monospacedMeta)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func refreshTimeMachineItems() {
        timeMachineItems = V4TimeMachineStore.loadItems(historyDirectory: model.localStore.historyDirectory)
    }

    private var notificationReadinessText: String {
        switch magicianNotificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "本地通知已允许"
        case .notDetermined:
            return "还没请求通知权限"
        case .denied:
            return "通知权限未开启"
        case .unknown:
            return "通知状态暂时未知"
        }
    }

    private var clockHandoffReadinessText: String {
        if magicianClockAlarmSurfaceAvailable || magicianClockTimerSurfaceAvailable || magicianClockAppAvailable {
            return "可以打开 Clock 或接近的系统入口"
        }
        return "这台 Mac 还没有可用的 Clock handoff"
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

    private func copyExecutionTraceMemoryText(_ entry: SessionHistoryEntry) {
        guard entry.mode == .selectionRewrite else {
            showToast("当前模式没有执行链路。")
            return
        }
        guard
            let trace = entry.magicianExecutionTrace?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !trace.isEmpty
        else {
            showToast("这条记录没有执行链路可复制。")
            return
        }
        writeTextToPasteboard(trace)
        showToast("已复制执行链路。")
    }

    private func copyExecutionInterpretationMemoryText(_ entry: SessionHistoryEntry) {
        guard entry.mode == .selectionRewrite else {
            showToast("当前模式没有执行解读。")
            return
        }
        guard
            let interpretation = MemoryEntryTextResolver.magicianExecutionInterpretation(for: entry)
        else {
            showToast("这条记录还没有执行解读可复制。")
            return
        }
        writeTextToPasteboard(interpretation)
        showToast("已复制执行解读。")
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
