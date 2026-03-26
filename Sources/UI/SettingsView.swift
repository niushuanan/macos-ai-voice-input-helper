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

    private enum BrainstormCaptureMode {
        case modifierTap
    }

    @ObservedObject private var controlCenterState: ControlCenterState
    @ObservedObject private var hotkeyStateStore: HotkeyStateStore
    @ObservedObject private var permissionsCenter: PermissionsCenter
    @ObservedObject private var providerSettingsStore: ProviderSettingsStore
    @ObservedObject private var asrDictionaryStore: ASRDictionaryStore
    @ObservedObject private var localSenseVoiceRuntimeManager: LocalSenseVoiceRuntimeManager
    @ObservedObject private var skillRuleStore: SkillRuleStore
    @ObservedObject private var appScenePolicyStore: AppScenePolicyStore
    @ObservedObject private var localHistoryStore: LocalHistoryStore
    @ObservedObject private var brainstormDurationProfileStore: BrainstormDurationProfileStore
    @ObservedObject private var toastPresenter: ToastPresenter
    @ObservedObject private var magicianFeatureToggleStore: MagicianFeatureToggleStore

    @State private var asrTesting = false
    @State private var textTesting = false
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
    @State private var isCapturingWakeModifier = false
    @State private var pendingWakeModifier: HotkeyModifier?
    @State private var wakeModifierCaptureHint: String?
    @State private var wakeModifierFlagsMonitor: Any?
    @State private var wakeModifierKeyDownMonitor: Any?
    @State private var activeBrainstormCaptureMode: BrainstormCaptureMode?
    @State private var pendingBrainstormModifier: HotkeyModifier?
    @State private var brainstormCaptureHint: String?
    @State private var brainstormFlagsMonitor: Any?
    @State private var brainstormKeyDownMonitor: Any?
    @State private var magicianPermissionPrompt: MagicianPermissionPromptModel?
    @State private var magicianEventAuthorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var magicianShortcutsAvailable = FileManager.default.isExecutableFile(atPath: "/usr/bin/shortcuts")
    @State private var magicianCreateNoteShortcutName = MagicianCreateNoteShortcutSupport().shortcutName
    @State private var magicianCreateNoteShortcutExists = MagicianCreateNoteShortcutSupport().hasShortcut()
    @State private var magicianNotesAppAvailable = MagicianNotesCapability.notesAppAvailable
    @State private var magicianComposeEmailAvailable = MagicianMailCapability.composeEmailServiceAvailable
    @State private var magicianMailtoAvailable = MagicianMailCapability.mailtoAvailable
    @State private var magicianMailAppAvailable = MagicianMailCapability.mailAppAvailable
    @State private var memoryToolbarAvailableWidth: CGFloat = 0
    @State private var memoryFilterBarWidth: CGFloat = 0
    @State private var clearMemoryButtonWidth: CGFloat = 0

    private let magicianStatusResolver = MagicianStatusResolver()

    init(model: AppModel) {
        self.model = model
        _controlCenterState = ObservedObject(wrappedValue: model.controlCenterState)
        _hotkeyStateStore = ObservedObject(wrappedValue: model.hotkeyStateStore)
        _permissionsCenter = ObservedObject(wrappedValue: model.permissionsCenter)
        _providerSettingsStore = ObservedObject(wrappedValue: model.providerSettingsStore)
        _asrDictionaryStore = ObservedObject(wrappedValue: model.asrDictionaryStore)
        _localSenseVoiceRuntimeManager = ObservedObject(wrappedValue: model.localSenseVoiceRuntimeManager)
        _skillRuleStore = ObservedObject(wrappedValue: model.skillRuleStore)
        _appScenePolicyStore = ObservedObject(wrappedValue: model.appScenePolicyStore)
        _localHistoryStore = ObservedObject(wrappedValue: model.localHistoryStore)
        _brainstormDurationProfileStore = ObservedObject(wrappedValue: model.brainstormDurationProfileStore)
        _toastPresenter = ObservedObject(wrappedValue: model.toastPresenter)
        _magicianFeatureToggleStore = ObservedObject(wrappedValue: model.magicianFeatureToggleStore)
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
            } else if section == .magician {
                refreshMagicianCapabilityState()
                permissionsCenter.refreshStatuses()
            } else if activeBrainstormCaptureMode != nil {
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
    }

    private var homePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader(
                    title: "首页",
                    subtitle: ""
                )

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
            Button("清空全部记录") {
                localHistoryStore.clearAll()
                showToast("会话明细已清空，首页累计指标保持不变。")
            }
            .keyboardShortcut(.defaultAction)
            Button("取消", role: .cancel) {}
        } message: {
            Text("该操作会删除记忆页全部本地记录，但不影响首页累计指标。")
        }
    }

    private var magicianPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(
                    title: "魔术先生",
                    subtitle: "选中文字，开口一句，立马搞定。哎呦不错哦～"
                )

                magicianTriggerGuideCard

                ForEach(MagicianFeatureDescriptor.all) { descriptor in
                    magicianFeatureCard(descriptor)
                }
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

    private var magicianTriggerGuideCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("如何触发")
                .font(.headline)
            Text("长按主键（默认右 Shift）说命令，松开就会执行。")
                .font(.subheadline)
            Text("文字处理必须先选中内容；其余能力可直接说命令，无选中也能执行。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("示例：先选中一段文本后长按主键说“翻成日语”；或选中一段活动通知后说“帮我建立日程”。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .pulseCard(cornerRadius: 12)
    }

    private func magicianFeatureCard(_ descriptor: MagicianFeatureDescriptor) -> some View {
        let resolution = magicianStatusResolver.resolve(
            feature: descriptor.id,
            isEnabled: magicianFeatureToggleStore.isEnabled(descriptor.id),
            dependencies: currentMagicianDependencies
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Label(descriptor.name, systemImage: descriptor.symbolName)
                    .font(.headline)
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: {
                            magicianFeatureToggleStore.isEnabled(descriptor.id)
                        },
                        set: { enabled in
                            handleMagicianToggleChange(
                                feature: descriptor.id,
                                enabled: enabled
                            )
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .scaleEffect(0.8)
                .fixedSize()
            }

            Text(descriptor.summary)
                .font(.subheadline)

            Text("边界：\(descriptor.boundary)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("示例：\(descriptor.example)")
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

    private var skillsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                pageHeader(
                    title: "Skill",
                    subtitle: ""
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
                    subtitle: ""
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
                    subtitle: "在这里管理快捷键、权限和基础信息。"
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
                    subtitle: "用于短时讨论记录，自动整理为可直接给 AI 分析的上下文。"
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
            captureBracketButton(
                valueText: pendingBrainstormModifier?.displayName ?? hotkeyStateStore.brainstormModifier.displayName,
                isCapturing: activeBrainstormCaptureMode == .modifierTap
            ) {
                startBrainstormModifierCapture()
            }

            if activeBrainstormCaptureMode == .modifierTap, let brainstormCaptureHint {
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

    private func captureBracketButton(
        valueText: String,
        isCapturing: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text("[ \(valueText) ]")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(isCapturing ? "录入中" : "点击录入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                isCapturing
                                    ? Color.accentColor
                                    : Color.primary.opacity(0.2),
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
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

                    Button {
                        startWakeModifierCapture()
                    } label: {
                        HStack(spacing: 10) {
                            Text("[ \(pendingWakeModifier?.displayName ?? hotkeyStateStore.wakeModifier.displayName) ]")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(isCapturingWakeModifier ? "录入中" : "点击录入")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(
                                            isCapturingWakeModifier
                                                ? Color.accentColor
                                                : Color.primary.opacity(0.2),
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)

                    if let wakeModifierCaptureHint {
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

            if permissionsCenter.runtimeDiagnostics.bundlePath != "/Applications/PulseType.app" {
                Label(
                    "当前不是 /Applications/PulseType.app。建议用安装脚本覆盖到 /Applications，避免权限反复重置。",
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
        ProviderType.allCases.filter(\.supportsTranscription)
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
    private func pageHeader(title: String, subtitle: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.bold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
            mailAppAvailable: magicianMailAppAvailable
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
    }

    private func handleMagicianToggleChange(
        feature: MagicianFeatureID,
        enabled: Bool
    ) {
        if !enabled {
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
        case let .blocked(reason, prompt):
            magicianFeatureToggleStore.setEnabled(false, for: feature)
            magicianPermissionPrompt = prompt
            showToast(reason)
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
        Button("清空记录", role: .destructive) {
            showClearMemoryConfirmation = true
        }
        .buttonStyle(.bordered)
        .disabled(localHistoryStore.entries.isEmpty)
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
        isCapturingWakeModifier = true
        pendingWakeModifier = nil
        wakeModifierCaptureHint = "请按左/右修饰键，然后按 Enter 确认。"

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
        isCapturingWakeModifier = false
        pendingWakeModifier = nil
        wakeModifierCaptureHint = nil
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
        guard isCapturingWakeModifier else {
            return
        }
        guard let modifier = HotkeyModifier.from(keyCode: event.keyCode) else {
            return
        }
        pendingWakeModifier = modifier
        wakeModifierCaptureHint = "已捕获 \(modifier.displayName)。按 Enter 确认，按 Esc 取消。"
    }

    private func handleWakeModifierKeyDown(_ event: NSEvent) -> NSEvent? {
        guard isCapturingWakeModifier else {
            return event
        }

        switch event.keyCode {
        case 36, 76:
            guard let modifier = pendingWakeModifier else {
                wakeModifierCaptureHint = "还没有捕获到修饰键，请先按目标键。"
                return nil
            }
            let updated = hotkeyStateStore.setModifier(modifier, for: .wakeSession)
            guard updated else {
                showToast("主键不能与一口气全念对单击修饰键相同，请先调整一口气全念对触发键。")
                return nil
            }
            showToast("主键已改为单键触发 · \(modifier.displayName)。")
            stopWakeModifierCapture()
            return nil
        case 53:
            stopWakeModifierCapture()
            showToast("已取消主键修改。")
            return nil
        default:
            if pendingWakeModifier == nil {
                wakeModifierCaptureHint = "请先按目标修饰键，再按 Enter。"
            } else if let pendingWakeModifier {
                wakeModifierCaptureHint = "已捕获 \(pendingWakeModifier.displayName)。按 Enter 确认，按 Esc 取消。"
            }
            return nil
        }
    }

    private func startBrainstormModifierCapture() {
        stopWakeModifierCapture()
        stopBrainstormCapture()
        activeBrainstormCaptureMode = .modifierTap
        pendingBrainstormModifier = nil
        brainstormCaptureHint = "请按左/右修饰键，然后按 Enter 确认。"

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
        activeBrainstormCaptureMode = nil
        pendingBrainstormModifier = nil
        brainstormCaptureHint = nil
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
        guard activeBrainstormCaptureMode == .modifierTap else {
            return
        }
        guard let modifier = HotkeyModifier.from(keyCode: event.keyCode) else {
            return
        }
        pendingBrainstormModifier = modifier
        brainstormCaptureHint = "已捕获 \(modifier.displayName)。按 Enter 确认，按 Esc 取消。"
    }

    private func handleBrainstormModifierKeyDown(_ event: NSEvent) -> NSEvent? {
        guard activeBrainstormCaptureMode == .modifierTap else {
            return event
        }

        switch event.keyCode {
        case 36, 76:
            guard let pendingBrainstormModifier else {
                brainstormCaptureHint = "还没有捕获到修饰键，请先按目标键。"
                return nil
            }
            hotkeyStateStore.setBrainstormModifier(pendingBrainstormModifier)
            showToast("一口气全念对修饰键已更新。")
            stopBrainstormCapture()
            return nil
        case 53:
            stopBrainstormCapture()
            showToast("已取消一口气全念对修饰键修改。")
            return nil
        default:
            if pendingBrainstormModifier == nil {
                brainstormCaptureHint = "请先按目标修饰键，再按 Enter。"
            } else if let pendingBrainstormModifier {
                brainstormCaptureHint = "已捕获 \(pendingBrainstormModifier.displayName)。按 Enter 确认，按 Esc 取消。"
            }
            return nil
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
    let onCopyPrimary: () -> Void
    let onCopyDialogue: () -> Void
    let onCopyRaw: () -> Void
    let onCopyCommand: () -> Void
    let onDelete: () -> Void
    @State private var brainstormDetailsExpanded = false

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
                    .buttonStyle(.bordered)
                    .disabled(!hasBrainstormDetails)
                }

                Button("删除", role: .destructive) {
                    onDelete()
                }
                .buttonStyle(.bordered)
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

    private var singleCopyText: String? {
        MemoryEntryTextResolver.defaultText(for: entry)
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
                    .toggleStyle(SwitchToggleStyle())
                    .scaleEffect(0.8)
                    .fixedSize()
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
    let isEditing: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(policy.appName)
                    .font(.subheadline.weight(.semibold))
                if isEditing {
                    Text("编辑中")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule(style: .continuous).fill(Color.accentColor.opacity(0.14)))
                }
                Spacer()
                Button("编辑") {
                    onEdit()
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

            Text(promptPreview)
                .font(.caption)
                .foregroundStyle(promptPreview == "还没有专属提示词。" ? .secondary : .primary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Label("应用提示词", systemImage: "text.bubble")
                    .font(.caption2)
                Label("普通听写/改写", systemImage: "wand.and.stars")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .pulseCard(cornerRadius: 10)
    }

    private var promptPreview: String {
        let value = policy.appPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            return "还没有专属提示词。"
        }
        return value
    }
}

private struct SceneAppCandidateRowView: View {
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
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.65))
        )
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

private struct MagicianPermissionSheetView: View {
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
                .buttonStyle(.bordered)

                Button(prompt.primaryButtonTitle) {
                    onPrimary()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 430)
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
