import AppKit
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

struct MagicianAgentStep: Codable, Equatable, Identifiable {
    let id: String
    let workflowStep: MagicianWorkflowStep

    init(id: String, workflowStep: MagicianWorkflowStep) {
        self.id = id
        self.workflowStep = workflowStep
    }
}

struct MagicianAgentPlan: Codable, Equatable {
    let version: Int
    let steps: [MagicianAgentStep]
    let maxAutoReplans: Int
    let maxAutoRetries: Int
    let rationale: String?
    let confidence: Double

    init(
        version: Int = 1,
        steps: [MagicianAgentStep],
        maxAutoReplans: Int = 1,
        maxAutoRetries: Int = 1,
        rationale: String? = nil,
        confidence: Double = 0.8
    ) {
        self.version = version
        self.steps = steps
        self.maxAutoReplans = max(0, min(maxAutoReplans, 1))
        self.maxAutoRetries = max(0, min(maxAutoRetries, 1))
        self.rationale = rationale
        self.confidence = confidence
    }

    init(workflowPlan: MagicianWorkflowPlan, maxAutoReplans: Int = 1, maxAutoRetries: Int = 1) {
        self.init(
            version: workflowPlan.version,
            steps: workflowPlan.steps.map { MagicianAgentStep(id: $0.stepID, workflowStep: $0) },
            maxAutoReplans: maxAutoReplans,
            maxAutoRetries: maxAutoRetries,
            rationale: workflowPlan.rationale,
            confidence: workflowPlan.confidence
        )
    }
}

struct MagicianAgentExecutionResult: Equatable {
    let executionResult: MagicianExecutionResult
    let observation: MagicianAgentObservation?
    let targetResolution: MagicianTargetResolution?
    let replanned: Bool

    init(
        executionResult: MagicianExecutionResult,
        observation: MagicianAgentObservation? = nil,
        targetResolution: MagicianTargetResolution? = nil,
        replanned: Bool = false
    ) {
        self.executionResult = executionResult
        self.observation = observation
        self.targetResolution = targetResolution
        self.replanned = replanned
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

protocol MagicianReplanPolicy {
    func shouldAutoReplan(
        after error: MagicianError,
        step: MagicianWorkflowStep,
        attempt: Int
    ) -> Bool
}

struct DefaultMagicianReplanPolicy: MagicianReplanPolicy {
    func shouldAutoReplan(
        after error: MagicianError,
        step: MagicianWorkflowStep,
        attempt: Int
    ) -> Bool {
        guard attempt <= 1 else {
            return false
        }
        guard step.feature == .feishuCLI else {
            return false
        }
        switch error.code {
        case .intentParseFailed, .cliAuthRequired, .toolExecutionFailed:
            return true
        default:
            return false
        }
    }
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
                case .createNote, .composeEmailDraft, .createEvent:
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
        case .createEvent, .createNote, .composeEmailDraft:
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
        case .createEvent, .createNote, .composeEmailDraft, .feishuCLI:
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
            params.mailBody = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : inputText
            params.mailDeliveryMode = action.instruction.lowercased().contains("草稿") ? .draftOnly : .autoSendIfResolved
        case .createEvent:
            params.notes = inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : inputText
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
        case .feishuCLI:
            return ["飞书", "feishu", "lark"]
        case .textTransform:
            return []
        }
    }
}
