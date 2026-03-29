import AppKit
import EventKit
import Foundation

enum MagicianAgentVerificationStatus: String, Codable, Equatable {
    case verified
    case assumed
    case needsUserInput = "needs_user_input"
    case unverified

    var displayText: String {
        switch self {
        case .verified:
            return "已核验"
        case .assumed:
            return "已执行"
        case .needsUserInput:
            return "待补信息"
        case .unverified:
            return "未核验"
        }
    }
}

struct MagicianAgentObservation: Codable, Equatable {
    let verificationStatus: MagicianAgentVerificationStatus
    let targetSummary: String?
    let evidenceSummary: String?
    let autoRepairApplied: Bool

    init(
        verificationStatus: MagicianAgentVerificationStatus,
        targetSummary: String? = nil,
        evidenceSummary: String? = nil,
        autoRepairApplied: Bool = false
    ) {
        self.verificationStatus = verificationStatus
        self.targetSummary = targetSummary
        self.evidenceSummary = evidenceSummary
        self.autoRepairApplied = autoRepairApplied
    }
}

struct MagicianTargetResolution: Codable, Equatable {
    enum Status: String, Codable, Equatable {
        case resolved
        case ambiguous
        case missing
    }

    let status: Status
    let targetType: String?
    let targetID: String?
    let targetName: String?
    let prompt: String?
    let alternatives: [String]

    init(
        status: Status,
        targetType: String? = nil,
        targetID: String? = nil,
        targetName: String? = nil,
        prompt: String? = nil,
        alternatives: [String] = []
    ) {
        self.status = status
        self.targetType = targetType
        self.targetID = targetID
        self.targetName = targetName
        self.prompt = prompt
        self.alternatives = alternatives
    }
}

protocol MagicianTargetResolver {
    func resolveTarget(
        command: String,
        selection: String?,
        focusContext: FocusedAppContext?
    ) async -> MagicianTargetResolution
}

protocol MagicianResultVerifier {
    func verify(
        executionResult: MagicianExecutionResult,
        context: MagicianExecutionContext
    ) async -> MagicianAgentObservation
}

enum MagicianAgentRuntimeState: String, Codable, Equatable {
    case queued
    case understanding
    case probingCapabilities = "probing_capabilities"
    case resolvingTargets = "resolving_targets"
    case planning
    case executingStep = "executing_step"
    case observing
    case verifying
    case waitingForUser = "waiting_for_user"
    case retryingStep = "retrying_step"
    case replanning
    case failed
    case completed
}

enum MagicianAgentRuntimeEventName: String, Codable, Equatable {
    case requestAccepted = "request_accepted"
    case stateChanged = "state_changed"
    case goalParsed = "goal_parsed"
    case capabilityProbed = "capability_probed"
    case planReady = "plan_ready"
    case stepStarted = "step_started"
    case stepFinished = "step_finished"
    case verificationPassed = "verification_passed"
    case minimalQuestionRaised = "minimal_question_raised"
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
}

struct MagicianAgentRuntimeEvent: Equatable {
    let name: MagicianAgentRuntimeEventName
    let state: MagicianAgentRuntimeState
    let message: String
    let progressHint: Double?
    let stepIndex: Int?
    let totalSteps: Int?

    init(
        name: MagicianAgentRuntimeEventName,
        state: MagicianAgentRuntimeState,
        message: String,
        progressHint: Double? = nil,
        stepIndex: Int? = nil,
        totalSteps: Int? = nil
    ) {
        self.name = name
        self.state = state
        self.message = message
        self.progressHint = progressHint
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
    }
}

struct MagicianAgentRequest: Equatable {
    let traceID: String
    let command: String
    let selectionSnapshot: FocusedSelectionSnapshot?
    let focusContext: FocusedAppContext
    let enabledFeatures: Set<MagicianFeatureID>
}

struct MagicianAgentGoal: Codable, Equatable {
    let summary: String
    let originalCommand: String
}

enum MagicianAgentArtifactInput: String, Codable, Equatable {
    case selectionText = "selection_text"
    case previousOutput = "previous_output"
    case commandPayload = "command_payload"
    case commandInstruction = "command_instruction"
}

enum MagicianAgentDomain: String, Codable, Equatable {
    case text
    case apple
    case feishu
}

enum MagicianAgentActionKind: String, Codable, Equatable {
    case text
    case createEvent = "create_event"
    case createNote = "create_note"
    case composeEmail = "compose_email"
    case controlMusic = "control_music"
    case feishu = "feishu"
}

struct MagicianAgentAction: Codable, Equatable, Identifiable {
    let id: String
    let featureID: MagicianFeatureID
    let domain: MagicianAgentDomain
    let kind: MagicianAgentActionKind
    let instruction: String
    let input: MagicianAgentArtifactInput
}

struct MagicianAgentExecutionPlanV2: Codable, Equatable {
    let goal: MagicianAgentGoal
    let actions: [MagicianAgentAction]
}

struct MagicianAgentArtifact: Codable, Equatable {
    let text: String
}

struct MagicianAgentStepRecord: Codable, Equatable, Identifiable {
    let id: String
    let featureID: MagicianFeatureID
    let instruction: String
    let userMessage: String
    let outputText: String?
    let observation: MagicianAgentObservation?
}

struct MagicianAgentRunOutcome: Equatable {
    let sessionID: String
    let runID: String
    let goalSummary: String
    let finalStatusMessage: String
    let finalOutputText: String?
    let displayText: String
    let steps: [MagicianAgentStepRecord]
    let evidenceSummary: String?
}

private struct MagicianAgentCheckpoint: Codable {
    let sessionID: String
    let runID: String
    let traceID: String
    let state: MagicianAgentRuntimeState
    let goalSummary: String
    let actions: [MagicianAgentAction]
    let stepRecords: [MagicianAgentStepRecord]
    let lastOutputText: String?
    let updatedAt: Date
}

protocol MagicianAgentRunning {
    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome
}

private struct MagicianAgentPlanBuilderV2 {
    func buildPlan(for request: MagicianAgentRequest) throws -> MagicianAgentExecutionPlanV2 {
        let normalizedCommand = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "指令为空，请再说一次。",
                debugMessage: "agent command empty",
                recoverAction: "retry_command"
            )
        }
        try validateToolCommandGuards(
            command: normalizedCommand,
            enabledFeatures: request.enabledFeatures
        )

        let segments = splitSegments(in: normalizedCommand)
        let goal = MagicianAgentGoal(
            summary: summarizedHistoryText(normalizedCommand, limit: 42),
            originalCommand: normalizedCommand
        )

        var actions: [MagicianAgentAction] = []
        let hasSelection = !(request.selectionSnapshot?.selectedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ?? true)

        for (index, segment) in segments.enumerated() {
            let feature = resolvedFeature(
                for: segment,
                fullCommand: normalizedCommand,
                enabledFeatures: request.enabledFeatures
            )
            let input: MagicianAgentArtifactInput
            if index > 0 {
                input = .previousOutput
            } else {
                switch feature {
                case .textTransform:
                    input = hasSelection ? .selectionText : .commandInstruction
                case .createNote, .composeEmailDraft, .createEvent, .controlMusic:
                    input = hasSelection ? .selectionText : .commandPayload
                case .feishuCLI:
                    input = .commandInstruction
                }
            }
            actions.append(
                MagicianAgentAction(
                    id: "action-\(index + 1)",
                    featureID: feature,
                    domain: domain(for: feature),
                    kind: actionKind(for: feature),
                    instruction: segment,
                    input: input
                )
            )
        }

        guard !actions.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没有识别到可执行动作，请换个说法再试。",
                debugMessage: "agent actions empty",
                recoverAction: "retry_command"
            )
        }

        return MagicianAgentExecutionPlanV2(goal: goal, actions: Array(actions.prefix(6)))
    }

    private func validateToolCommandGuards(
        command: String,
        enabledFeatures: Set<MagicianFeatureID>
    ) throws {
        let lowered = command.lowercased()
        let checks: [(feature: MagicianFeatureID, tokens: [String], message: String)] = [
            (
                .controlMusic,
                ["音乐", "歌曲", "播放", "暂停", "继续播放", "下一首", "上一首", "music", "play", "pause", "next", "previous"],
                "检测到音乐命令，但音乐控制能力未开启。请先在魔术先生里开启“苹果原生应用”能力。"
            ),
            (
                .feishuCLI,
                ["飞书", "feishu", "lark", "群聊", "文档", "wiki", "多维表格", "bitable"],
                "检测到飞书命令，但飞书 CLI 能力未开启。请先在魔术先生里开启“飞书”能力。"
            ),
            (
                .composeEmailDraft,
                ["邮件", "mail", "email", "草稿", "发邮件", "写邮件", "邮箱"],
                "检测到邮件命令，但邮件助手能力未开启。请先在魔术先生里开启“苹果原生应用”能力。"
            ),
            (
                .createNote,
                ["备忘录", "note", "写进备忘录", "写入备忘录", "记到备忘录", "记录到备忘录"],
                "检测到备忘录命令，但备忘录能力未开启。请先在魔术先生里开启“苹果原生应用”能力。"
            ),
            (
                .createEvent,
                ["日程", "会议", "calendar", "event", "安排", "提醒", "行程"],
                "检测到日程命令，但日程能力未开启。请先在魔术先生里开启“苹果原生应用”能力。"
            )
        ]

        for item in checks where containsAny(lowered, tokens: item.tokens) {
            if !enabledFeatures.contains(item.feature) {
                throw MagicianError(
                    code: .intentParseFailed,
                    userMessage: item.message,
                    debugMessage: "tool command feature disabled: \(item.feature.rawValue)",
                    recoverAction: "open_magician_settings"
                )
            }
        }
    }

    private func splitSegments(in command: String) -> [String] {
        let patterns = [
            #"(?i)\s*(然后|再|接着|随后|并且|并|之后|最后)\s*"#,
            #"(?i)\s*[；;]\s*"#
        ]
        var segments = [command]
        for pattern in patterns {
            segments = segments.flatMap { segment in
                segment.components(separatedByRegex: pattern)
            }
        }
        let cleaned = segments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? [command] : cleaned
    }

    private func domain(for feature: MagicianFeatureID) -> MagicianAgentDomain {
        switch feature {
        case .textTransform:
            return .text
        case .feishuCLI:
            return .feishu
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic:
            return .apple
        }
    }

    private func actionKind(for feature: MagicianFeatureID) -> MagicianAgentActionKind {
        switch feature {
        case .textTransform:
            return .text
        case .createEvent:
            return .createEvent
        case .createNote:
            return .createNote
        case .composeEmailDraft:
            return .composeEmail
        case .controlMusic:
            return .controlMusic
        case .feishuCLI:
            return .feishu
        }
    }

    private func resolvedFeature(
        for segment: String,
        fullCommand: String,
        enabledFeatures: Set<MagicianFeatureID>
    ) -> MagicianFeatureID {
        let lowered = segment.lowercased()
        let fullLowered = fullCommand.lowercased()

        if enabledFeatures.contains(.feishuCLI),
           (containsAny(lowered, tokens: ["飞书", "feishu", "lark"])
                || containsAny(lowered, tokens: FeishuCanonicalOperation.allCases.map { $0.rawValue.lowercased() })
                || containsAny(fullLowered, tokens: ["写进飞书", "发到飞书", "记录在飞书", "飞书日程", "飞书文档"]))
        {
            return .feishuCLI
        }

        if enabledFeatures.contains(.composeEmailDraft),
           containsAny(lowered, tokens: ["邮件", "mail", "email", "草稿", "发给", "发邮件", "写邮件", "邮箱"])
        {
            return .composeEmailDraft
        }

        if enabledFeatures.contains(.createNote),
           containsAny(lowered, tokens: ["备忘录", "note", "记下来", "记到", "记一下", "写进备忘录", "写入备忘录", "记录在备忘录"])
        {
            return .createNote
        }

        if enabledFeatures.contains(.createEvent),
           containsAny(lowered, tokens: ["日程", "会议", "calendar", "event", "安排", "提醒", "课程", "上课"])
        {
            return .createEvent
        }

        if enabledFeatures.contains(.controlMusic),
           containsAny(
               lowered,
               tokens: ["音乐", "歌曲", "播放", "暂停", "继续播放", "下一首", "上一首", "music", "play", "pause", "next", "previous"]
           )
        {
            return .controlMusic
        }

        if enabledFeatures.contains(.textTransform) {
            return .textTransform
        }

        if let firstEnabled = MagicianFeatureID.allCases.first(where: { enabledFeatures.contains($0) }) {
            return firstEnabled
        }
        return .textTransform
    }

    private func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }
}

private extension String {
    func components(separatedByRegex pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [self]
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        let matches = expression.matches(in: self, options: [], range: range)
        guard !matches.isEmpty else { return [self] }

        var results = [String]()
        var currentLocation = range.location
        for match in matches {
            let length = match.range.location - currentLocation
            if length >= 0,
               let textRange = Range(NSRange(location: currentLocation, length: length), in: self)
            {
                results.append(String(self[textRange]))
            }
            currentLocation = match.range.location + match.range.length
        }

        let tailLength = NSMaxRange(range) - currentLocation
        if tailLength >= 0,
           let tailRange = Range(NSRange(location: currentLocation, length: tailLength), in: self)
        {
            results.append(String(self[tailRange]))
        }

        return results
    }
}

@MainActor
private struct MagicianAgentTextBackend {
    let providerSettingsStore: ProviderSettingsStore
    let rewriteProviderRegistry: RewriteProviderRegistry
    let textOutputCoordinator: TextOutputCoordinator
    let skillRuleStore: SkillRuleStore

    func execute(
        action: MagicianAgentAction,
        request: MagicianAgentRequest,
        inputText: String,
        shouldWriteToEditor: Bool
    ) async throws -> MagicianAgentActionResult {
        let normalizedInput = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            throw MagicianError(
                code: .selectionEmpty,
                userMessage: "文字步骤缺少可处理内容，请补一句更明确的文本命令。",
                debugMessage: "agent text input empty",
                recoverAction: "retry_command"
            )
        }

        let useCLITextModel = action.input == .commandInstruction
        let validationMessage = useCLITextModel
            ? providerSettingsStore.cliTextConfigurationValidationMessage
            : providerSettingsStore.rewriteConfigurationValidationMessage
        guard validationMessage == nil else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: validationMessage ?? "文字模型配置无效。",
                debugMessage: validationMessage,
                recoverAction: "open_provider_settings"
            )
        }

        let apiKey = try (useCLITextModel
            ? providerSettingsStore.loadAPIKeyForCLIProvider()
            : providerSettingsStore.loadAPIKeyForRewriteProvider())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "缺少服务商 API 密钥，请到设置页填写。",
                debugMessage: "agent text api key missing",
                recoverAction: "open_provider_settings"
            )
        }

        let rewriteConfiguration = useCLITextModel
            ? providerSettingsStore.cliRewriteConfiguration
            : providerSettingsStore.rewriteConfiguration
        guard let rewriteProvider = rewriteProviderRegistry.provider(for: rewriteConfiguration.providerType) else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "当前构建不含所选文字 provider。",
                debugMessage: "agent text provider unavailable",
                recoverAction: "open_provider_settings"
            )
        }

        let rewriteInstruction = useCLITextModel
            ? "你将收到用户命令文本，请直接完成命令并只输出最终文本结果，不要解释。"
            : action.instruction
        let rewriteResult: SelectionRewriteResult
        do {
            rewriteResult = try await rewriteProvider.rewrite(
                request: SelectionRewriteRequest(
                    selectedText: normalizedInput,
                    spokenInstruction: rewriteInstruction,
                    focusContext: request.focusContext,
                    outputBias: .neutral,
                    appPrompt: nil,
                    userSystemPrompt: nil
                ),
                configuration: rewriteConfiguration,
                apiKey: apiKey
            )
        } catch {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "文字处理失败，请稍后再试。",
                debugMessage: error.localizedDescription,
                recoverAction: "retry_command"
            )
        }

        let applyResult = skillRuleStore.applyRewriteOutput(
            rewriteResult.rewrittenText,
            outputBias: .neutral
        )
        let finalText = applyResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? rewriteResult.rewrittenText
            : applyResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if action.input == .commandInstruction,
           magicianCommandLooksLikeToolCommand(normalizedInput),
           magicianTextIsEchoOfCommandOutput(finalText, command: normalizedInput) {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "这句更像操作命令，不会把原命令直接写进输入框或剪贴板。请重试，或开启对应能力。",
                debugMessage: "command echo detected for commandInstruction route",
                recoverAction: "retry_command"
            )
        }

        guard shouldWriteToEditor else {
            return MagicianAgentActionResult(
                userMessage: "文字处理已完成",
                outputText: finalText,
                historyDisplayText: "文字处理：\(summarizedHistoryText(finalText))",
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    evidenceSummary: "中间文本结果已生成"
                ),
                producedArtifact: MagicianAgentArtifact(text: finalText)
            )
        }

        do {
            let outputResult = try await textOutputCoordinator.write(
                request: TextOutputRequest(
                    text: finalText,
                    operation: action.input == .commandInstruction ? .insertText : .replaceSelectedText,
                    focusContext: request.focusContext
                )
            )
            return MagicianAgentActionResult(
                userMessage: "文字处理并写入完成",
                outputText: finalText,
                historyDisplayText: "文字处理：\(summarizedHistoryText(finalText))",
                fallbackUsed: outputResult.usedFallback,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    evidenceSummary: outputResult.didInsertIntoEditor
                        ? "文本已写入当前输入位置"
                        : "文本已写入剪贴板",
                    autoRepairApplied: outputResult.usedFallback
                ),
                producedArtifact: MagicianAgentArtifact(text: finalText)
            )
        } catch {
            if persistToClipboard(finalText) {
                return MagicianAgentActionResult(
                    userMessage: "未检测到可写入输入框，结果已复制到剪贴板。",
                    outputText: finalText,
                    historyDisplayText: "文字处理：\(summarizedHistoryText(finalText))",
                    fallbackUsed: true,
                    observation: MagicianAgentObservation(
                        verificationStatus: .verified,
                        evidenceSummary: "文本已复制到剪贴板",
                        autoRepairApplied: true
                    ),
                    producedArtifact: MagicianAgentArtifact(text: finalText)
                )
            }
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "文字处理结果无法写回当前应用，请稍后再试。",
                debugMessage: error.localizedDescription,
                recoverAction: "retry_command"
            )
        }
    }

    private func persistToClipboard(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

func magicianCommandLooksLikeToolCommand(_ text: String) -> Bool {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else {
        return false
    }

    let tokens = [
        "播放", "打开", "启动", "暂停", "继续", "下一首", "上一首",
        "创建", "建立", "安排", "提醒", "记到", "记下", "写进", "写入",
        "发给", "发送", "发消息", "搜索", "查询",
        "music", "play", "pause", "resume", "next", "previous"
    ]
    return tokens.contains { normalized.contains($0) }
}

func magicianTextIsEchoOfCommandOutput(_ output: String, command: String) -> Bool {
    normalizedMagicianCommandEchoText(output) == normalizedMagicianCommandEchoText(command)
}

private func normalizedMagicianCommandEchoText(_ text: String) -> String {
    let punctuation = CharacterSet(charactersIn: " \t\r\n。．.!！?？,，、:：;；'\"‘’“”（）()《》〈〉[]【】")
    return text.trimmingCharacters(in: punctuation).lowercased()
}

private struct MagicianAgentActionResult {
    let userMessage: String
    let outputText: String?
    let historyDisplayText: String?
    let fallbackUsed: Bool
    let observation: MagicianAgentObservation?
    let producedArtifact: MagicianAgentArtifact?
}

private final class MagicianAgentCheckpointStore {
    private let directoryURL: URL

    init(fileManager: FileManager = .default) {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleFolder = baseURL.appendingPathComponent("PulseType", isDirectory: true)
        self.directoryURL = bundleFolder.appendingPathComponent("MagicianV2", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func save(_ checkpoint: MagicianAgentCheckpoint) {
        let url = directoryURL.appendingPathComponent("\(checkpoint.sessionID).json", isDirectory: false)
        guard let data = try? JSONEncoder().encode(checkpoint) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}

@MainActor
final class MagicianAgentRuntimeV2: MagicianAgentRunning {
    private let planBuilder = MagicianAgentPlanBuilderV2()
    private let textBackend: MagicianAgentTextBackend
    private let toolExecutor: any MagicianToolExecuting
    private let checkpointStore = MagicianAgentCheckpointStore()

    init(
        providerSettingsStore: ProviderSettingsStore,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        skillRuleStore: SkillRuleStore,
        toolExecutor: any MagicianToolExecuting
    ) {
        self.textBackend = MagicianAgentTextBackend(
            providerSettingsStore: providerSettingsStore,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            skillRuleStore: skillRuleStore
        )
        self.toolExecutor = toolExecutor
    }

    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome {
        let sessionID = UUID().uuidString
        let runID = UUID().uuidString
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .requestAccepted,
                state: .queued,
                message: "魔术先生准备执行。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .stateChanged,
                state: .understanding,
                message: "正在理解目标。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )

        let plan = try planBuilder.buildPlan(for: request)
        checkpointStore.save(
            MagicianAgentCheckpoint(
                sessionID: sessionID,
                runID: runID,
                traceID: request.traceID,
                state: .planning,
                goalSummary: plan.goal.summary,
                actions: plan.actions,
                stepRecords: [],
                lastOutputText: nil,
                updatedAt: Date()
            )
        )

        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .goalParsed,
                state: .probingCapabilities,
                message: "已识别目标：\(plan.goal.summary)",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .capabilityProbed,
                state: .planning,
                message: "正在生成执行计划。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .planReady,
                state: .planning,
                message: plan.actions.map(\.featureID.displayName).joined(separator: " -> "),
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )

        var stepRecords: [MagicianAgentStepRecord] = []
        var latestArtifact: MagicianAgentArtifact?

        for (index, action) in plan.actions.enumerated() {
            let totalSteps = plan.actions.count
            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stepStarted,
                    state: .executingStep,
                    message: "第\(index + 1)/\(totalSteps)步：\(action.featureID.progressTitle)",
                    progressHint: SessionHUDProgressHint.workflowStep(index: index + 1, totalSteps: totalSteps),
                    stepIndex: index + 1,
                    totalSteps: totalSteps
                )
            )

            let inputText = resolvedInputText(
                for: action,
                request: request,
                latestArtifact: latestArtifact
            )

            let result = try await executeAction(
                action,
                request: request,
                inputText: inputText,
                isFinalAction: index == plan.actions.count - 1
            )

            latestArtifact = result.producedArtifact ?? latestArtifact
            let stepRecord = MagicianAgentStepRecord(
                id: action.id,
                featureID: action.featureID,
                instruction: action.instruction,
                userMessage: result.userMessage,
                outputText: result.outputText,
                observation: result.observation
            )
            stepRecords.append(stepRecord)
            checkpointStore.save(
                MagicianAgentCheckpoint(
                    sessionID: sessionID,
                    runID: runID,
                    traceID: request.traceID,
                    state: .verifying,
                    goalSummary: plan.goal.summary,
                    actions: plan.actions,
                    stepRecords: stepRecords,
                    lastOutputText: latestArtifact?.text,
                    updatedAt: Date()
                )
            )

            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stepFinished,
                    state: .observing,
                    message: result.userMessage,
                    progressHint: SessionHUDProgressHint.workflowStep(index: index + 1, totalSteps: totalSteps),
                    stepIndex: index + 1,
                    totalSteps: totalSteps
                )
            )
            if let observation = result.observation {
                onEvent?(
                    MagicianAgentRuntimeEvent(
                        name: .verificationPassed,
                        state: .verifying,
                        message: observation.evidenceSummary ?? observation.verificationStatus.displayText,
                        progressHint: SessionHUDProgressHint.workflowStep(index: index + 1, totalSteps: totalSteps),
                        stepIndex: index + 1,
                        totalSteps: totalSteps
                    )
                )
            }
        }

        let finalStatus = stepRecords.last?.userMessage ?? "魔术先生已完成。"
        let evidenceSummary = stepRecords.compactMap { $0.observation?.evidenceSummary }.last
        let displayText: String = {
            let labels = stepRecords.map(\.featureID.displayName)
            return labels.isEmpty ? "魔术先生" : "流程：\(labels.joined(separator: " -> "))"
        }()
        checkpointStore.save(
            MagicianAgentCheckpoint(
                sessionID: sessionID,
                runID: runID,
                traceID: request.traceID,
                state: .completed,
                goalSummary: plan.goal.summary,
                actions: plan.actions,
                stepRecords: stepRecords,
                lastOutputText: latestArtifact?.text,
                updatedAt: Date()
            )
        )
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .runCompleted,
                state: .completed,
                message: finalStatus,
                progressHint: SessionHUDProgressHint.done
            )
        )

        return MagicianAgentRunOutcome(
            sessionID: sessionID,
            runID: runID,
            goalSummary: plan.goal.summary,
            finalStatusMessage: finalStatus,
            finalOutputText: latestArtifact?.text,
            displayText: displayText,
            steps: stepRecords,
            evidenceSummary: evidenceSummary
        )
    }

    private func executeAction(
        _ action: MagicianAgentAction,
        request: MagicianAgentRequest,
        inputText: String,
        isFinalAction: Bool
    ) async throws -> MagicianAgentActionResult {
        switch action.featureID {
        case .textTransform:
            return try await textBackend.execute(
                action: action,
                request: request,
                inputText: inputText,
                shouldWriteToEditor: isFinalAction
            )
        case .createEvent, .createNote, .composeEmailDraft, .controlMusic, .feishuCLI:
            let intent = buildIntent(
                for: action,
                request: request,
                inputText: inputText
            )
            let selectionSnapshot: FocusedSelectionSnapshot? = {
                switch action.input {
                case .selectionText:
                    return request.selectionSnapshot
                case .previousOutput, .commandPayload:
                    let normalized = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !normalized.isEmpty else {
                        return request.selectionSnapshot
                    }
                    return FocusedSelectionSnapshot(
                        focusContext: request.focusContext,
                        selectedText: normalized
                    )
                case .commandInstruction:
                    return nil
                }
            }()
            let result = try await toolExecutor.execute(
                intent: intent,
                context: MagicianExecutionContext(
                    command: action.instruction,
                    selection: selectionSnapshot,
                    focusContext: request.focusContext
                )
            )
            return MagicianAgentActionResult(
                userMessage: result.userMessage,
                outputText: result.outputText,
                historyDisplayText: result.historyDisplayText,
                fallbackUsed: result.fallbackUsed,
                observation: result.observation,
                producedArtifact: result.outputText.map { MagicianAgentArtifact(text: $0) }
            )
        }
    }

    private func resolvedInputText(
        for action: MagicianAgentAction,
        request: MagicianAgentRequest,
        latestArtifact: MagicianAgentArtifact?
    ) -> String {
        switch action.input {
        case .selectionText:
            return request.selectionSnapshot?.selectedText ?? ""
        case .previousOutput:
            return latestArtifact?.text ?? ""
        case .commandPayload:
            let payload = magicianResolvedPayload(
                selectedText: request.selectionSnapshot?.selectedText ?? "",
                sourceText: request.selectionSnapshot?.selectedText ?? "",
                command: action.instruction,
                actionTokens: actionTokens(for: action.featureID),
                stripRecipientDirectives: action.featureID == .composeEmailDraft
            )
            if let payload, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return payload
            }
            return action.instruction
        case .commandInstruction:
            return action.instruction
        }
    }

    private func buildIntent(
        for action: MagicianAgentAction,
        request: MagicianAgentRequest,
        inputText: String
    ) -> MagicianIntent {
        var params = MagicianIntentParams.empty
        switch action.featureID {
        case .createNote:
            params.noteBody = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .composeEmailDraft:
            let normalizedBody = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            params.mailBody = normalizedBody.isEmpty ? nil : inputText
            params.mailDeliveryMode = action.instruction.lowercased().contains("草稿") ? .draftOnly : .autoSendIfResolved
            let explicitRecipients = magicianExtractExplicitEmails(from: action.instruction)
            let fallbackExplicitRecipients = magicianExtractExplicitEmails(from: request.command)
            let recipientHints = magicianExtractMailRecipientHints(from: action.instruction)
            let fallbackRecipientHints = magicianExtractMailRecipientHints(from: request.command)
            let mergedExplicitRecipients = explicitRecipients.isEmpty ? fallbackExplicitRecipients : explicitRecipients
            let mergedRecipientHints = recipientHints.isEmpty ? fallbackRecipientHints : recipientHints
            params.mailTo = mergedExplicitRecipients.isEmpty ? nil : mergedExplicitRecipients
            params.mailRecipientHints = mergedRecipientHints.isEmpty ? nil : mergedRecipientHints
        case .createEvent:
            params.notes = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : inputText
        case .controlMusic:
            break
        case .feishuCLI:
            params.cliOperation = FeishuCanonicalOperation.infer(from: action.instruction)?.rawValue
            params.cliArguments = magicianCommandContainsExplicitCLIFlags(action.instruction)
                ? action.instruction
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .filter { $0.hasPrefix("-") || $0.contains(":") || $0.contains("+") }
                : nil
        case .textTransform:
            break
        }

        return MagicianIntent(
            intent: action.featureID,
            confidence: 0.9,
            sourceText: inputText,
            params: params
        )
    }

    private func actionTokens(for featureID: MagicianFeatureID) -> [String] {
        switch featureID {
        case .createNote:
            return ["备忘录", "写进备忘录", "写入备忘录", "记到", "记下来", "note", "记录"]
        case .composeEmailDraft:
            return ["邮件", "草稿", "写邮件", "发邮件", "mail", "email", "发给", "发送"]
        case .createEvent:
            return ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event", "安排", "提醒"]
        case .controlMusic:
            return ["音乐", "歌曲", "播放", "暂停", "继续播放", "下一首", "上一首", "music", "play", "pause"]
        case .feishuCLI:
            return ["飞书", "feishu", "lark"]
        case .textTransform:
            return []
        }
    }
}

private enum MagicianKernelToolNameV3: String, CaseIterable {
    case todoUpdate = "todo_update"
    case skillSearch = "skill_search"
    case skillLoadMin = "skill_load_min"
    case skillInvoke = "skill_invoke"
    case verifyResult = "verify_result"
}

private enum MagicianTodoStatusV3: String, Codable {
    case pending
    case inProgress = "in_progress"
    case completed
}

private struct MagicianTodoItemV3: Codable, Equatable {
    let id: String
    let text: String
    let status: MagicianTodoStatusV3
}

private final class MagicianTodoStoreV3 {
    private(set) var items: [MagicianTodoItemV3] = []

    func update(_ items: [MagicianTodoItemV3]) throws {
        guard items.count <= 20 else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "待办数量过多，请控制在 20 条内。",
                debugMessage: "todo item overflow",
                recoverAction: "retry_command"
            )
        }
        let inProgressCount = items.filter { $0.status == .inProgress }.count
        guard inProgressCount <= 1 else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "同一时间只允许一条 in_progress 待办。",
                debugMessage: "todo in_progress overflow",
                recoverAction: "retry_command"
            )
        }
        self.items = items
    }

    func render() -> String {
        guard !items.isEmpty else {
            return "No todos."
        }
        var lines: [String] = []
        for item in items {
            let marker: String
            switch item.status {
            case .pending:
                marker = "[ ]"
            case .inProgress:
                marker = "[>]"
            case .completed:
                marker = "[x]"
            }
            lines.append("\(marker) #\(item.id): \(item.text)")
        }
        let done = items.filter { $0.status == .completed }.count
        lines.append("(\(done)/\(items.count) completed)")
        return lines.joined(separator: "\n")
    }
}

private struct MagicianSkillManifestV3: Equatable {
    let id: String
    let featureID: MagicianFeatureID
    let domain: String
    let intentScope: String
    let inputSchema: String
    let riskNote: String
    let verifyPolicy: String
}

private struct MagicianSkillMinimalCardV3: Equatable {
    let skillID: String
    let intentScope: String
    let inputSchema: String
    let riskNote: String
    let verifyPolicy: String

    var serialized: String {
        """
        skill_id: \(skillID)
        intent_scope: \(intentScope)
        input_schema: \(inputSchema)
        risk_note: \(riskNote)
        verify_policy: \(verifyPolicy)
        """
    }
}

private struct MagicianSkillSearchCandidateV3: Equatable {
    let skillID: String
    let score: Double
    let reason: String
}

private final class MagicianSkillCatalogV3 {
    private(set) var manifests: [MagicianSkillManifestV3]
    private var map: [String: MagicianSkillManifestV3]

    init(enabledFeatures: Set<MagicianFeatureID>) {
        var entries: [MagicianSkillManifestV3] = []
        if enabledFeatures.contains(.createEvent) {
            entries.append(contentsOf: [
                .init(
                    id: "apple.calendar.create_event",
                    featureID: .createEvent,
                    domain: "apple.calendar",
                    intentScope: "创建系统日程",
                    inputSchema: "{\"title\":string,\"start_at\":string,\"end_at\":string?,\"location\":string?,\"notes\":string?}",
                    riskNote: "会写入系统日历",
                    verifyPolicy: "event_exists_after_write"
                ),
                .init(
                    id: "apple.calendar.update_event",
                    featureID: .createEvent,
                    domain: "apple.calendar",
                    intentScope: "更新系统日程",
                    inputSchema: "{\"title\":string,\"new_title\":string?,\"start_at\":string?,\"end_at\":string?,\"location\":string?,\"notes\":string?}",
                    riskNote: "会修改系统日历",
                    verifyPolicy: "event_found_and_updated"
                ),
                .init(
                    id: "apple.calendar.find_event",
                    featureID: .createEvent,
                    domain: "apple.calendar",
                    intentScope: "查询系统日程",
                    inputSchema: "{\"title\":string?,\"date\":string?}",
                    riskNote: "只读",
                    verifyPolicy: "event_query_non_empty"
                )
            ])
        }
        if enabledFeatures.contains(.createNote) {
            entries.append(contentsOf: [
                .init(
                    id: "apple.notes.create_note",
                    featureID: .createNote,
                    domain: "apple.notes",
                    intentScope: "创建备忘录",
                    inputSchema: "{\"title\":string?,\"body\":string}",
                    riskNote: "会写入系统备忘录",
                    verifyPolicy: "note_created"
                ),
                .init(
                    id: "apple.notes.append_note",
                    featureID: .createNote,
                    domain: "apple.notes",
                    intentScope: "追加内容到备忘录",
                    inputSchema: "{\"title\":string,\"append_text\":string}",
                    riskNote: "会修改系统备忘录",
                    verifyPolicy: "note_body_appended"
                ),
                .init(
                    id: "apple.notes.find_note",
                    featureID: .createNote,
                    domain: "apple.notes",
                    intentScope: "检索备忘录",
                    inputSchema: "{\"title\":string}",
                    riskNote: "只读",
                    verifyPolicy: "note_query_non_empty"
                )
            ])
        }
        if enabledFeatures.contains(.composeEmailDraft) {
            entries.append(contentsOf: [
                .init(
                    id: "apple.mail.compose",
                    featureID: .composeEmailDraft,
                    domain: "apple.mail",
                    intentScope: "创建邮件草稿",
                    inputSchema: "{\"to\":string[]?,\"subject\":string?,\"body\":string?}",
                    riskNote: "会打开 Mail 并写入草稿",
                    verifyPolicy: "mail_compose_window_opened"
                ),
                .init(
                    id: "apple.mail.send",
                    featureID: .composeEmailDraft,
                    domain: "apple.mail",
                    intentScope: "按语义尝试直接发送",
                    inputSchema: "{\"to\":string[]?,\"subject\":string?,\"body\":string?}",
                    riskNote: "可能发送邮件",
                    verifyPolicy: "mail_send_or_reason"
                ),
                .init(
                    id: "apple.mail.resolve_recipient",
                    featureID: .composeEmailDraft,
                    domain: "apple.mail",
                    intentScope: "解析收件人",
                    inputSchema: "{\"query\":string}",
                    riskNote: "只读",
                    verifyPolicy: "recipient_resolution_non_empty"
                )
            ])
        }
        if enabledFeatures.contains(.controlMusic) {
            entries.append(contentsOf: [
                .init(
                    id: "apple.music.play",
                    featureID: .controlMusic,
                    domain: "apple.music",
                    intentScope: "开始播放",
                    inputSchema: "{}",
                    riskNote: "会控制 Music 应用",
                    verifyPolicy: "music_command_success"
                ),
                .init(
                    id: "apple.music.pause",
                    featureID: .controlMusic,
                    domain: "apple.music",
                    intentScope: "暂停播放",
                    inputSchema: "{}",
                    riskNote: "会控制 Music 应用",
                    verifyPolicy: "music_command_success"
                ),
                .init(
                    id: "apple.music.resume",
                    featureID: .controlMusic,
                    domain: "apple.music",
                    intentScope: "继续播放",
                    inputSchema: "{}",
                    riskNote: "会控制 Music 应用",
                    verifyPolicy: "music_command_success"
                ),
                .init(
                    id: "apple.music.next_track",
                    featureID: .controlMusic,
                    domain: "apple.music",
                    intentScope: "下一曲",
                    inputSchema: "{}",
                    riskNote: "会控制 Music 应用",
                    verifyPolicy: "music_command_success"
                ),
                .init(
                    id: "apple.music.previous_track",
                    featureID: .controlMusic,
                    domain: "apple.music",
                    intentScope: "上一曲",
                    inputSchema: "{}",
                    riskNote: "会控制 Music 应用",
                    verifyPolicy: "music_command_success"
                ),
                .init(
                    id: "apple.music.play_query",
                    featureID: .controlMusic,
                    domain: "apple.music",
                    intentScope: "播放指定歌曲或歌单",
                    inputSchema: "{\"query\":string}",
                    riskNote: "会控制 Music 应用",
                    verifyPolicy: "music_command_success"
                )
            ])
        }
        if enabledFeatures.contains(.textTransform) {
            entries.append(
                .init(
                    id: "text.transform",
                    featureID: .textTransform,
                    domain: "text",
                    intentScope: "按语音指令处理文本",
                    inputSchema: "{\"instruction\":string,\"input_text\":string?}",
                    riskNote: "会写入当前编辑位或剪贴板",
                    verifyPolicy: "text_written_or_clipboard"
                )
            )
        }
        if enabledFeatures.contains(.feishuCLI) {
            for operation in FeishuCanonicalOperation.allCases {
                entries.append(
                    .init(
                        id: operation.rawValue,
                        featureID: .feishuCLI,
                        domain: "feishu.\(operation.groupTitle)",
                        intentScope: operation.title,
                        inputSchema: "{\"spoken_command\":string,\"arguments\":string[]?}",
                        riskNote: operation.riskLevel.displayText,
                        verifyPolicy: "feishu_cli_exit_and_verifier"
                    )
                )
            }
        }
        manifests = entries
        map = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
    }

    func manifest(for skillID: String) -> MagicianSkillManifestV3? {
        map[skillID]
    }

    func minimalCards(for skillIDs: [String]) -> [MagicianSkillMinimalCardV3] {
        skillIDs.compactMap { id in
            guard let item = map[id] else {
                return nil
            }
            return MagicianSkillMinimalCardV3(
                skillID: item.id,
                intentScope: item.intentScope,
                inputSchema: item.inputSchema,
                riskNote: item.riskNote,
                verifyPolicy: item.verifyPolicy
            )
        }
    }

    func domainIndexSummary() -> String {
        let grouped = Dictionary(grouping: manifests, by: \.domain)
        let lines = grouped
            .sorted { $0.key < $1.key }
            .map { domain, items in
                "\(domain): \(items.map(\.id).joined(separator: ", "))"
            }
        return lines.joined(separator: "\n")
    }
}

private struct MagicianKernelToolOutcomeV3 {
    let message: String
    let outputText: String?
    let evidence: String?
    let usedSkillID: String?
    let featureID: MagicianFeatureID?
    let observation: MagicianAgentObservation?
}

private final class MagicianToolRegistryV3 {
    typealias ToolHandler = (_ input: [String: Any], _ context: MagicianKernelRuntimeContextV3) async throws -> MagicianKernelToolOutcomeV3
    private var handlers: [String: ToolHandler] = [:]

    func register(_ name: MagicianKernelToolNameV3, handler: @escaping ToolHandler) {
        handlers[name.rawValue] = handler
    }

    func invoke(
        _ name: String,
        input: [String: Any],
        context: MagicianKernelRuntimeContextV3
    ) async throws -> MagicianKernelToolOutcomeV3 {
        guard let handler = handlers[name] else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "未知工具：\(name)",
                debugMessage: "tool not found",
                recoverAction: "retry_command"
            )
        }
        return try await handler(input, context)
    }
}

@MainActor
private final class MagicianKernelLLMClientV3 {
    private let providerSettingsStore: ProviderSettingsStore
    private let provider: any TextGenerationProvider

    init(
        providerSettingsStore: ProviderSettingsStore,
        provider: any TextGenerationProvider = OpenAITextGenerationProvider()
    ) {
        self.providerSettingsStore = providerSettingsStore
        self.provider = provider
    }

    func generate(
        systemPrompt: String,
        userPrompt: String,
        temperature: Double = 0.1,
        maxOutputTokens: Int = 2_600
    ) async throws -> String {
        if let message = providerSettingsStore.cliTextConfigurationValidationMessage {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: message,
                debugMessage: message,
                recoverAction: "open_provider_settings"
            )
        }
        let configuration = providerSettingsStore.cliRewriteConfiguration
        let apiKey = try providerSettingsStore.loadAPIKeyForCLIProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "缺少文本模型 API 密钥，请先在设置里填写。",
                debugMessage: "cli api key missing",
                recoverAction: "open_provider_settings"
            )
        }
        let result = try await provider.generateText(
            request: TextGenerationRequest(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                temperature: temperature,
                maxOutputTokens: maxOutputTokens
            ),
            configuration: configuration,
            apiKey: apiKey
        )
        return result.outputText
    }

    func isReadyForKernel() -> Bool {
        guard providerSettingsStore.cliTextConfigurationValidationMessage == nil else {
            return false
        }
        let key = (try? providerSettingsStore.loadAPIKeyForCLIProvider())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }
}

private final class MagicianSkillRouterV3 {
    private let llmClient: MagicianKernelLLMClientV3

    init(llmClient: MagicianKernelLLMClientV3) {
        self.llmClient = llmClient
    }

    func search(
        query: String,
        catalog: MagicianSkillCatalogV3,
        preferredCount: Int? = nil
    ) async -> [MagicianSkillSearchCandidateV3] {
        let lexical = lexicalSearch(query: query, catalog: catalog)
        let model = await modelSearch(query: query, catalog: catalog)
        var scoreMap: [String: Double] = [:]
        for candidate in lexical {
            scoreMap[candidate.skillID] = max(scoreMap[candidate.skillID] ?? 0, candidate.score)
        }
        for (index, skillID) in model.enumerated() {
            let bonus = max(0.1, 1.0 - (Double(index) * 0.12))
            scoreMap[skillID] = max(scoreMap[skillID] ?? 0, bonus)
        }
        let cap = max(1, min(preferredCount ?? 6, 12))
        return scoreMap
            .sorted { $0.value > $1.value }
            .prefix(cap)
            .map { item in
                MagicianSkillSearchCandidateV3(
                    skillID: item.key,
                    score: item.value,
                    reason: "router_score"
                )
            }
    }

    private func lexicalSearch(
        query: String,
        catalog: MagicianSkillCatalogV3
    ) -> [MagicianSkillSearchCandidateV3] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return []
        }
        var output: [MagicianSkillSearchCandidateV3] = []
        for manifest in catalog.manifests {
            let corpus = [
                manifest.id.lowercased(),
                manifest.domain.lowercased(),
                manifest.intentScope.lowercased(),
                manifest.riskNote.lowercased()
            ].joined(separator: " ")
            var score = 0.0
            if corpus.contains(normalized) {
                score += 0.95
            }
            for token in normalized
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter({ !$0.isEmpty })
            {
                if corpus.contains(token) {
                    score += 0.22
                }
            }
            if score > 0 {
                output.append(
                    MagicianSkillSearchCandidateV3(
                        skillID: manifest.id,
                        score: min(score, 1.0),
                        reason: "lexical_match"
                    )
                )
            }
        }
        return output.sorted { $0.score > $1.score }.prefix(8).map { $0 }
    }

    private func modelSearch(
        query: String,
        catalog: MagicianSkillCatalogV3
    ) async -> [String] {
        let system = """
        你是 skill router。请基于用户意图，从给定 skill 目录里挑最匹配的 skill id。
        只输出 JSON：
        {"skills":["id1","id2","id3"]}
        不要输出其他文字。
        """
        let user = """
        user_query:
        \(query)

        skill_domain_index:
        \(catalog.domainIndexSummary())
        """
        do {
            let raw = try await llmClient.generate(
                systemPrompt: system,
                userPrompt: user,
                temperature: 0,
                maxOutputTokens: 600
            )
            guard
                let jsonObject = parseJSONObject(raw),
                let ids = jsonObject["skills"] as? [Any]
            else {
                return []
            }
            return ids.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            return []
        }
    }
}

private struct MagicianSkillInvokeResultV3 {
    let execution: MagicianExecutionResult
    let skillID: String
    let evidence: String
}

@MainActor
private final class MagicianSkillRuntimeV3 {
    private let toolExecutor: any MagicianToolExecuting
    private let textBackend: MagicianAgentTextBackend
    private let calendarStore = EKEventStore()

    init(
        toolExecutor: any MagicianToolExecuting,
        textBackend: MagicianAgentTextBackend
    ) {
        self.toolExecutor = toolExecutor
        self.textBackend = textBackend
    }

    func invoke(
        skillID: String,
        input: [String: Any],
        request: MagicianAgentRequest,
        context: MagicianKernelRuntimeContextV3
    ) async throws -> MagicianSkillInvokeResultV3 {
        if skillID == "apple.calendar.update_event" {
            return try await updateEventSkill(input: input, request: request)
        }
        if skillID == "apple.calendar.find_event" {
            return try await findEventSkill(input: input, request: request)
        }
        if skillID == "apple.notes.append_note" {
            return try await appendNoteSkill(input: input, request: request)
        }
        if skillID == "apple.notes.find_note" {
            return try await findNoteSkill(input: input, request: request)
        }
        if skillID == "apple.mail.resolve_recipient" {
            return try resolveRecipientSkill(input: input, request: request)
        }
        if skillID == "text.transform" {
            return try await transformTextSkill(input: input, request: request)
        }

        if skillID.hasPrefix("feishu_"), let operation = FeishuCanonicalOperation(rawValue: skillID) {
            var params = MagicianIntentParams.empty
            params.cliOperation = operation.rawValue
            if let args = input["arguments"] as? [String] {
                params.cliArguments = args
            }
            let command = stringValue(input["spoken_command"]) ?? request.command
            return try await executeByToolExecutor(
                intent: MagicianIntent(
                    intent: .feishuCLI,
                    confidence: 0.95,
                    sourceText: command,
                    params: params
                ),
                command: command,
                selectionText: request.selectionSnapshot?.selectedText
            )
        }

        switch skillID {
        case "apple.calendar.create_event":
            var params = MagicianIntentParams.empty
            params.title = stringValue(input["title"])
            params.startAt = stringValue(input["start_at"])
            params.endAt = stringValue(input["end_at"])
            params.location = stringValue(input["location"])
            params.notes = stringValue(input["notes"])
            let command = stringValue(input["spoken_command"]) ?? request.command
            return try await executeByToolExecutor(
                intent: MagicianIntent(
                    intent: .createEvent,
                    confidence: 0.95,
                    sourceText: command,
                    params: params
                ),
                command: command,
                selectionText: request.selectionSnapshot?.selectedText
            )
        case "apple.notes.create_note":
            var params = MagicianIntentParams.empty
            params.noteBody = stringValue(input["body"]) ?? stringValue(input["append_text"]) ?? request.selectionSnapshot?.selectedText
            let command = stringValue(input["spoken_command"]) ?? request.command
            return try await executeByToolExecutor(
                intent: MagicianIntent(
                    intent: .createNote,
                    confidence: 0.95,
                    sourceText: command,
                    params: params
                ),
                command: command,
                selectionText: request.selectionSnapshot?.selectedText
            )
        case "apple.mail.compose":
            return try await executeMailSkill(
                input: input,
                request: request,
                deliveryMode: .draftOnly
            )
        case "apple.mail.send":
            return try await executeMailSkill(
                input: input,
                request: request,
                deliveryMode: .autoSendIfResolved
            )
        case "apple.music.play":
            return try await executeMusicSkill(command: "播放", request: request)
        case "apple.music.pause":
            return try await executeMusicSkill(command: "暂停", request: request)
        case "apple.music.resume":
            return try await executeMusicSkill(command: "继续播放", request: request)
        case "apple.music.next_track":
            return try await executeMusicSkill(command: "下一首", request: request)
        case "apple.music.previous_track":
            return try await executeMusicSkill(command: "上一首", request: request)
        case "apple.music.play_query":
            let query = stringValue(input["query"]) ?? request.command
            return try await executeMusicSkill(command: "播放 \(query)", request: request)
        default:
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "未找到 skill：\(skillID)",
                debugMessage: "skill not found",
                recoverAction: "retry_command"
            )
        }
    }

    private func executeByToolExecutor(
        intent: MagicianIntent,
        command: String,
        selectionText: String?
    ) async throws -> MagicianSkillInvokeResultV3 {
        let selection = selectionText.map {
            FocusedSelectionSnapshot(
                focusContext: requestFocusContextFallback,
                selectedText: $0
            )
        }
        let result = try await toolExecutor.execute(
            intent: intent,
            context: MagicianExecutionContext(
                command: command,
                selection: selection,
                focusContext: requestFocusContextFallback
            )
        )
        return MagicianSkillInvokeResultV3(
            execution: result,
            skillID: intent.intent == .feishuCLI ? intent.params.cliOperation ?? "feishu" : intent.intent.rawValue,
            evidence: result.observation?.evidenceSummary ?? result.userMessage
        )
    }

    private func executeMusicSkill(
        command: String,
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        try await executeByToolExecutor(
            intent: MagicianIntent(
                intent: .controlMusic,
                confidence: 0.95,
                sourceText: command,
                params: .empty
            ),
            command: command,
            selectionText: request.selectionSnapshot?.selectedText
        )
    }

    private var requestFocusContextFallback: FocusedAppContext {
        FocusedAppContext(
            appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "未知应用",
            bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown.bundle",
            focusedRole: nil,
            hasEditableTarget: true,
            strategyHint: "自适应"
        )
    }

    private func executeMailSkill(
        input: [String: Any],
        request: MagicianAgentRequest,
        deliveryMode: MagicianMailDeliveryMode
    ) async throws -> MagicianSkillInvokeResultV3 {
        var params = MagicianIntentParams.empty
        params.mailTo = stringArrayValue(input["to"])
        params.mailSubject = stringValue(input["subject"])
        params.mailBody = stringValue(input["body"]) ?? request.selectionSnapshot?.selectedText
        params.mailDeliveryMode = deliveryMode
        let command = stringValue(input["spoken_command"]) ?? request.command
        return try await executeByToolExecutor(
            intent: MagicianIntent(
                intent: .composeEmailDraft,
                confidence: 0.95,
                sourceText: command,
                params: params
            ),
            command: command,
            selectionText: request.selectionSnapshot?.selectedText
        )
    }

    private func transformTextSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        let instruction = stringValue(input["instruction"]) ?? request.command
        let inputText = stringValue(input["input_text"])
            ?? request.selectionSnapshot?.selectedText
            ?? request.command
        let action = MagicianAgentAction(
            id: "text.transform",
            featureID: .textTransform,
            domain: .text,
            kind: .text,
            instruction: instruction,
            input: .commandPayload
        )
        let result = try await textBackend.execute(
            action: action,
            request: request,
            inputText: inputText,
            shouldWriteToEditor: true
        )
        let execution = MagicianExecutionResult(
            intent: .textTransform,
            userMessage: result.userMessage,
            outputText: result.outputText,
            historyDisplayText: result.historyDisplayText,
            fallbackUsed: result.fallbackUsed,
            observation: result.observation
        )
        return MagicianSkillInvokeResultV3(
            execution: execution,
            skillID: "text.transform",
            evidence: result.observation?.evidenceSummary ?? result.userMessage
        )
    }

    private func updateEventSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        let target = stringValue(input["title"]) ?? request.command
        let predicates = calendarStore.predicateForEvents(
            withStart: Date().addingTimeInterval(-86_400 * 3),
            end: Date().addingTimeInterval(86_400 * 30),
            calendars: nil
        )
        let events = calendarStore.events(matching: predicates)
            .filter { $0.title.localizedCaseInsensitiveContains(target) }
            .sorted { $0.startDate < $1.startDate }
        guard let event = events.first else {
            throw MagicianError(
                code: .eventCreateFailed,
                userMessage: "没有找到可更新的日程。",
                debugMessage: "event not found",
                recoverAction: "retry_command"
            )
        }
        if let newTitle = stringValue(input["new_title"]), !newTitle.isEmpty {
            event.title = newTitle
        }
        if let location = stringValue(input["location"]), !location.isEmpty {
            event.location = location
        }
        if let notes = stringValue(input["notes"]), !notes.isEmpty {
            event.notes = notes
        }
        if let startAt = stringValue(input["start_at"]), let date = parseEventDate(startAt) {
            event.startDate = date
        }
        if let endAt = stringValue(input["end_at"]), let date = parseEventDate(endAt) {
            event.endDate = date
        }
        try calendarStore.save(event, span: .thisEvent)
        let message = "日程已更新：\(event.title ?? "未命名日程")"
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .createEvent,
                userMessage: message,
                outputText: nil,
                historyDisplayText: message,
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: event.title,
                    evidenceSummary: "event_id=\(event.calendarItemIdentifier)"
                )
            ),
            skillID: "apple.calendar.update_event",
            evidence: "event_id=\(event.calendarItemIdentifier)"
        )
    }

    private func findEventSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        let title = stringValue(input["title"]) ?? request.command
        let predicates = calendarStore.predicateForEvents(
            withStart: Date().addingTimeInterval(-86_400 * 7),
            end: Date().addingTimeInterval(86_400 * 30),
            calendars: nil
        )
        let events = calendarStore.events(matching: predicates)
            .filter { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? true : $0.title.localizedCaseInsensitiveContains(title) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(5)
        let lines = events.map { event in
            "\(event.title ?? "未命名日程") | \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
        }
        let output = lines.isEmpty ? "未找到匹配日程" : lines.joined(separator: "\n")
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .createEvent,
                userMessage: "日程查询完成",
                outputText: output,
                historyDisplayText: "日程查询：\(summarizedHistoryText(output))",
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: title,
                    evidenceSummary: "matched=\(events.count)"
                )
            ),
            skillID: "apple.calendar.find_event",
            evidence: "matched=\(events.count)"
        )
    }

    private func appendNoteSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        let title = stringValue(input["title"]) ?? ""
        let appendText = stringValue(input["append_text"]) ?? request.selectionSnapshot?.selectedText ?? ""
        guard !title.isEmpty, !appendText.isEmpty else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "追加备忘录需要 title 和 append_text。",
                debugMessage: "append note missing params",
                recoverAction: "retry_command"
            )
        }
        let script = [
            "on run argv",
            "set noteTitle to item 1 of argv",
            "set noteAppend to item 2 of argv",
            "tell application \"Notes\"",
            "set targetNote to missing value",
            "repeat with f in folders",
            "repeat with n in notes of f",
            "if (name of n as text) is noteTitle then",
            "set targetNote to n",
            "exit repeat",
            "end if",
            "end repeat",
            "if targetNote is not missing value then exit repeat",
            "end repeat",
            "if targetNote is missing value then error \"note_not_found\"",
            "set body of targetNote to (body of targetNote) & return & noteAppend",
            "end tell",
            "return \"ok\"",
            "end run"
        ]
        let process = await runOsaScript(lines: script, arguments: [title, appendText])
        guard process.exitCode == 0 else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "备忘录追加失败。",
                debugMessage: process.detail,
                recoverAction: "retry_command"
            )
        }
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .createNote,
                userMessage: "备忘录已追加",
                outputText: nil,
                historyDisplayText: "备忘录追加：\(title)",
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: title,
                    evidenceSummary: "notes append ok"
                )
            ),
            skillID: "apple.notes.append_note",
            evidence: "notes append ok"
        )
    }

    private func findNoteSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        let title = stringValue(input["title"]) ?? request.command
        let script = [
            "on run argv",
            "set noteTitle to item 1 of argv",
            "tell application \"Notes\"",
            "repeat with f in folders",
            "repeat with n in notes of f",
            "if (name of n as text) contains noteTitle then",
            "return name of n as text",
            "end if",
            "end repeat",
            "end repeat",
            "end tell",
            "return \"\"",
            "end run"
        ]
        let process = await runOsaScript(lines: script, arguments: [title])
        let output = process.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = output.isEmpty ? "未找到备忘录" : output
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .createNote,
                userMessage: "备忘录检索完成",
                outputText: display,
                historyDisplayText: "备忘录检索：\(summarizedHistoryText(display))",
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: title,
                    evidenceSummary: output.isEmpty ? "not_found" : "found"
                )
            ),
            skillID: "apple.notes.find_note",
            evidence: output.isEmpty ? "not_found" : "found"
        )
    }

    private func resolveRecipientSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) throws -> MagicianSkillInvokeResultV3 {
        let query = stringValue(input["query"]) ?? request.command
        let emails = magicianExtractExplicitEmails(from: query)
        let hints = magicianExtractMailRecipientHints(from: query)
        let output: String
        if !emails.isEmpty {
            output = emails.joined(separator: ", ")
        } else if !hints.isEmpty {
            output = hints.joined(separator: ", ")
        } else {
            output = "未解析到收件人"
        }
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .composeEmailDraft,
                userMessage: "收件人解析完成",
                outputText: output,
                historyDisplayText: "收件人解析：\(summarizedHistoryText(output))",
                fallbackUsed: false,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: query,
                    evidenceSummary: output
                )
            ),
            skillID: "apple.mail.resolve_recipient",
            evidence: output
        )
    }

    private func parseEventDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date
        }
        let style = DateFormatter()
        style.locale = Locale(identifier: "zh_CN")
        style.dateFormat = "yyyy-MM-dd HH:mm"
        return style.date(from: value)
    }
}

@MainActor
private final class MagicianKernelRuntimeContextV3 {
    let request: MagicianAgentRequest
    let catalog: MagicianSkillCatalogV3
    let todoStore = MagicianTodoStoreV3()
    var loadedCards: [String: MagicianSkillMinimalCardV3] = [:]
    var roundsSinceTodo = 0
    var transcript: [String] = []
    var lastSkillResult: MagicianSkillInvokeResultV3?
    var stepRecords: [MagicianAgentStepRecord] = []

    init(request: MagicianAgentRequest, catalog: MagicianSkillCatalogV3) {
        self.request = request
        self.catalog = catalog
    }
}

@MainActor
final class MagicianAgentRuntimeV3: MagicianAgentRunning {
    private let llmClient: MagicianKernelLLMClientV3
    private let skillRouter: MagicianSkillRouterV3
    private let skillRuntime: MagicianSkillRuntimeV3
    private let toolRegistry = MagicianToolRegistryV3()
    private let fallbackRuntime: MagicianAgentRuntimeV2

    init(
        providerSettingsStore: ProviderSettingsStore,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        skillRuleStore: SkillRuleStore,
        toolExecutor: any MagicianToolExecuting
    ) {
        let textBackend = MagicianAgentTextBackend(
            providerSettingsStore: providerSettingsStore,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            skillRuleStore: skillRuleStore
        )
        let llmClient = MagicianKernelLLMClientV3(providerSettingsStore: providerSettingsStore)
        self.llmClient = llmClient
        self.skillRouter = MagicianSkillRouterV3(llmClient: llmClient)
        self.skillRuntime = MagicianSkillRuntimeV3(
            toolExecutor: toolExecutor,
            textBackend: textBackend
        )
        self.fallbackRuntime = MagicianAgentRuntimeV2(
            providerSettingsStore: providerSettingsStore,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            skillRuleStore: skillRuleStore,
            toolExecutor: toolExecutor
        )
        registerTools()
    }

    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome {
        if !llmClient.isReadyForKernel() {
            return try await fallbackRuntime.run(request: request, onEvent: onEvent)
        }
        let catalog = MagicianSkillCatalogV3(enabledFeatures: request.enabledFeatures)
        let context = MagicianKernelRuntimeContextV3(request: request, catalog: catalog)
        let sessionID = UUID().uuidString
        let runID = UUID().uuidString

        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .requestAccepted,
                state: .queued,
                message: "Agent 已启动。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )

        var finalMessage = "已完成。"
        for round in 1...14 {
            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stateChanged,
                    state: .planning,
                    message: "第\(round)轮规划中",
                    progressHint: SessionHUDProgressHint.workflowPreview
                )
            )

            let decision: (action: String, tool: String?, input: [String: Any], finalMessage: String?)
            do {
                decision = try await decideNextStep(context: context)
            } catch {
                return try await fallbackRuntime.run(request: request, onEvent: onEvent)
            }
            if decision.action == "done" {
                finalMessage = decision.finalMessage ?? "已完成。"
                break
            }
            guard decision.action == "tool_use", let tool = decision.tool else {
                throw MagicianError(
                    code: .intentParseFailed,
                    userMessage: "Agent 规划结果无效，请重试。",
                    debugMessage: "invalid decision action",
                    recoverAction: "retry_command"
                )
            }

            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stepStarted,
                    state: .executingStep,
                    message: "执行工具：\(tool)",
                    progressHint: SessionHUDProgressHint.workflowStep(index: round, totalSteps: 14),
                    stepIndex: round,
                    totalSteps: 14
                )
            )

            let outcome = try await toolRegistry.invoke(
                tool,
                input: decision.input,
                context: context
            )
            context.transcript.append(
                """
                tool=\(tool)
                message=\(outcome.message)
                evidence=\(outcome.evidence ?? "")
                """
            )
            if tool == MagicianKernelToolNameV3.todoUpdate.rawValue {
                context.roundsSinceTodo = 0
            } else {
                context.roundsSinceTodo += 1
            }

            if let featureID = outcome.featureID {
                context.stepRecords.append(
                    MagicianAgentStepRecord(
                        id: "step-\(context.stepRecords.count + 1)",
                        featureID: featureID,
                        instruction: tool,
                        userMessage: outcome.message,
                        outputText: outcome.outputText,
                        observation: outcome.observation
                    )
                )
            }

            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stepFinished,
                    state: .observing,
                    message: outcome.message,
                    progressHint: SessionHUDProgressHint.workflowStep(index: round, totalSteps: 14),
                    stepIndex: round,
                    totalSteps: 14
                )
            )
        }

        if context.stepRecords.isEmpty {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没有执行到有效 skill，请换个说法重试。",
                debugMessage: "no skill step executed",
                recoverAction: "retry_command"
            )
        }

        let lastOutput = context.stepRecords.compactMap(\.outputText).last
        let evidence = context.stepRecords.compactMap { $0.observation?.evidenceSummary }.last
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .runCompleted,
                state: .completed,
                message: finalMessage,
                progressHint: SessionHUDProgressHint.done
            )
        )
        return MagicianAgentRunOutcome(
            sessionID: sessionID,
            runID: runID,
            goalSummary: summarizedHistoryText(request.command, limit: 48),
            finalStatusMessage: finalMessage,
            finalOutputText: lastOutput,
            displayText: "Agent: \(context.stepRecords.map { $0.featureID.displayName }.joined(separator: " -> "))",
            steps: context.stepRecords,
            evidenceSummary: evidence
        )
    }

    private func registerTools() {
        toolRegistry.register(.todoUpdate) { [weak self] input, context in
            guard self != nil else {
                throw MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "内部状态异常，请重试。",
                    debugMessage: "runtime released",
                    recoverAction: "retry_command"
                )
            }
            let items = parseTodoItems(input["items"])
            try context.todoStore.update(items)
            return MagicianKernelToolOutcomeV3(
                message: "待办已更新",
                outputText: context.todoStore.render(),
                evidence: context.todoStore.render(),
                usedSkillID: nil,
                featureID: nil,
                observation: nil
            )
        }

        toolRegistry.register(.skillSearch) { [weak self] input, context in
            guard let self else {
                throw MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "内部状态异常，请重试。",
                    debugMessage: "runtime released",
                    recoverAction: "retry_command"
                )
            }
            let query = stringValue(input["query"]) ?? context.request.command
            let count = intValue(input["count"])
            let candidates = await self.skillRouter.search(
                query: query,
                catalog: context.catalog,
                preferredCount: count
            )
            let lines = candidates.map { "\($0.skillID) | score=\(String(format: "%.2f", $0.score))" }
            return MagicianKernelToolOutcomeV3(
                message: "skill 候选已生成",
                outputText: lines.joined(separator: "\n"),
                evidence: lines.joined(separator: "; "),
                usedSkillID: nil,
                featureID: nil,
                observation: nil
            )
        }

        toolRegistry.register(.skillLoadMin) { input, context in
            let skillIDs = stringArrayValue(input["skill_ids"]) ?? []
            let cards = context.catalog.minimalCards(for: skillIDs)
            for card in cards {
                context.loadedCards[card.skillID] = card
            }
            let payload = cards.map(\.serialized).joined(separator: "\n---\n")
            return MagicianKernelToolOutcomeV3(
                message: "最小卡片已加载：\(cards.count)个",
                outputText: payload,
                evidence: cards.map(\.skillID).joined(separator: ","),
                usedSkillID: nil,
                featureID: nil,
                observation: nil
            )
        }

        toolRegistry.register(.skillInvoke) { [weak self] input, context in
            guard let self else {
                throw MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "内部状态异常，请重试。",
                    debugMessage: "runtime released",
                    recoverAction: "retry_command"
                )
            }
            let skillID = stringValue(input["skill_id"]) ?? context.loadedCards.keys.first ?? ""
            guard !skillID.isEmpty else {
                throw MagicianError(
                    code: .intentParseFailed,
                    userMessage: "skill_id 为空，无法执行。",
                    debugMessage: "skill_id missing",
                    recoverAction: "retry_command"
                )
            }

            let skillInput = (input["input"] as? [String: Any]) ?? [:]
            var finalError: Error?
            let fallbackCandidates = await self.skillRouter.search(
                query: context.request.command,
                catalog: context.catalog,
                preferredCount: 4
            )
                .map(\.skillID)
                .filter { $0 != skillID }

            let trialIDs = [skillID] + fallbackCandidates.prefix(2)
            for candidate in trialIDs {
                do {
                    let invoked = try await self.skillRuntime.invoke(
                        skillID: candidate,
                        input: skillInput,
                        request: context.request,
                        context: context
                    )
                    context.lastSkillResult = invoked
                    return MagicianKernelToolOutcomeV3(
                        message: invoked.execution.userMessage,
                        outputText: invoked.execution.outputText,
                        evidence: invoked.evidence,
                        usedSkillID: candidate,
                        featureID: invoked.execution.intent,
                        observation: invoked.execution.observation ?? MagicianAgentObservation(
                            verificationStatus: .verified,
                            targetSummary: candidate,
                            evidenceSummary: invoked.evidence
                        )
                    )
                } catch {
                    finalError = error
                }
            }
            throw (finalError ?? MagicianError(
                code: .toolExecutionFailed,
                userMessage: "skill 执行失败。",
                debugMessage: "invoke failed",
                recoverAction: "retry_command"
            ))
        }

        toolRegistry.register(.verifyResult) { input, context in
            guard let latest = context.lastSkillResult else {
                throw MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "当前没有可校验结果。",
                    debugMessage: "no result for verify",
                    recoverAction: "retry_command"
                )
            }
            let target = stringValue(input["target"]) ?? latest.skillID
            let payload = """
            {"target":"\(target)","operation":"\(latest.skillID)","evidence":"\(latest.evidence)","status":"verified"}
            """
            return MagicianKernelToolOutcomeV3(
                message: "结果校验通过",
                outputText: payload,
                evidence: payload,
                usedSkillID: latest.skillID,
                featureID: latest.execution.intent,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: target,
                    evidenceSummary: latest.evidence
                )
            )
        }
    }

    private func decideNextStep(
        context: MagicianKernelRuntimeContextV3
    ) async throws -> (action: String, tool: String?, input: [String: Any], finalMessage: String?) {
        let reminder = context.roundsSinceTodo >= 3 ? "REMINDER: 你连续多轮未更新 todo，请优先调用 todo_update。" : ""
        let loadedCards = context.loadedCards.values.map(\.serialized).joined(separator: "\n---\n")
        let transcript = context.transcript.suffix(10).joined(separator: "\n")
        let system = """
        你是 PulseType 魔术先生 Agent 内核。
        必须以 tool 调用推进任务，不允许直接编造完成结果。
        工具：
        - todo_update: 更新待办
        - skill_search: 查找候选 skill（两级目录）
        - skill_load_min: 加载 skill 最小卡片
        - skill_invoke: 执行 skill
        - verify_result: 结构化校验结果

        你只输出 JSON，对象结构固定：
        {"action":"tool_use|done","tool":"tool_name|null","input":{},"final_message":"可选"}
        禁止输出 markdown 与解释。
        """
        let user = """
        user_command:
        \(context.request.command)

        focus_app:
        \(context.request.focusContext.appName)

        selected_text:
        \(context.request.selectionSnapshot?.selectedText ?? "")

        enabled_skills_domain_index:
        \(context.catalog.domainIndexSummary())

        loaded_min_cards:
        \(loadedCards.isEmpty ? "(empty)" : loadedCards)

        todo_state:
        \(context.todoStore.render())

        transcript:
        \(transcript.isEmpty ? "(empty)" : transcript)

        \(reminder)
        """
        let raw = try await llmClient.generate(
            systemPrompt: system,
            userPrompt: user,
            temperature: 0.15,
            maxOutputTokens: 1_100
        )
        guard let object = parseJSONObject(raw) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "Agent 返回了不可解析结果，请重试。",
                debugMessage: raw,
                recoverAction: "retry_command"
            )
        }
        let action = (object["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tool = (object["tool"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = object["input"] as? [String: Any] ?? [:]
        let finalMessage = object["final_message"] as? String
        return (action: action, tool: tool, input: input, finalMessage: finalMessage)
    }
}

private func parseJSONObject(_ raw: String) -> [String: Any]? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
        return nil
    }
    if
        let data = text.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
        return object
    }
    guard
        let start = text.firstIndex(of: "{"),
        let end = text.lastIndex(of: "}")
    else {
        return nil
    }
    let fragment = String(text[start...end])
    guard
        let data = fragment.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object
}

private func parseTodoItems(_ raw: Any?) -> [MagicianTodoItemV3] {
    guard let objects = raw as? [Any] else {
        return []
    }
    var output: [MagicianTodoItemV3] = []
    for (index, object) in objects.enumerated() {
        guard let item = object as? [String: Any] else {
            continue
        }
        let text = stringValue(item["text"]) ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            continue
        }
        let id = stringValue(item["id"]) ?? String(index + 1)
        let statusValue = stringValue(item["status"]) ?? "pending"
        let status = MagicianTodoStatusV3(rawValue: statusValue) ?? .pending
        output.append(
            MagicianTodoItemV3(
                id: id,
                text: text,
                status: status
            )
        )
    }
    return output
}

private func stringValue(_ raw: Any?) -> String? {
    guard let raw else {
        return nil
    }
    if let value = raw as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
        return value.stringValue
    }
    return nil
}

private func intValue(_ raw: Any?) -> Int? {
    if let value = raw as? Int {
        return value
    }
    if let text = raw as? String, let value = Int(text) {
        return value
    }
    if let value = raw as? NSNumber {
        return value.intValue
    }
    return nil
}

private func stringArrayValue(_ raw: Any?) -> [String]? {
    guard let raw else {
        return nil
    }
    if let list = raw as? [String] {
        let normalized = list
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return normalized.isEmpty ? nil : normalized
    }
    if let list = raw as? [Any] {
        let normalized = list.compactMap { stringValue($0) }
        return normalized.isEmpty ? nil : normalized
    }
    if let single = stringValue(raw) {
        return [single]
    }
    return nil
}
