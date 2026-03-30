import AppKit
import EventKit
import Foundation

// MARK: - Agent Contracts

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

protocol MagicianAgentRunning {
    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome
}

// MARK: - Agent Text Backend

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

// MARK: - Kernel Todo + Skill Catalog

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

private struct MagicianSkillManifestDiskRecordV3: Decodable {
    let id: String
    let featureID: String
    let domain: String
    let intentScope: String
    let inputSchema: String
    let riskNote: String
    let verifyPolicy: String

    func asManifest() -> MagicianSkillManifestV3? {
        guard let feature = MagicianFeatureID(rawValue: featureID) else {
            return nil
        }
        return MagicianSkillManifestV3(
            id: id,
            featureID: feature,
            domain: domain,
            intentScope: intentScope,
            inputSchema: inputSchema,
            riskNote: riskNote,
            verifyPolicy: verifyPolicy
        )
    }
}

private final class MagicianSkillBundleMarkerV3 {}

private enum MagicianSkillManifestLoaderV3 {
    private static let relativeSkillManifestPath = "Sources/Resources/MagicianSkills/magician-skills.json"

    static func loadEnabledManifests(
        enabledFeatures: Set<MagicianFeatureID>
    ) -> [MagicianSkillManifestV3] {
        let records = loadDiskRecords()
        var output: [MagicianSkillManifestV3] = []
        var seen = Set<String>()
        for record in records {
            guard
                let manifest = record.asManifest(),
                enabledFeatures.contains(manifest.featureID),
                seen.insert(manifest.id).inserted
            else {
                continue
            }
            output.append(manifest)
        }
        return output
    }

    private static func loadDiskRecords() -> [MagicianSkillManifestDiskRecordV3] {
        let decoder = JSONDecoder()
        for url in candidateURLs() {
            guard
                let data = try? Data(contentsOf: url),
                let records = try? decoder.decode([MagicianSkillManifestDiskRecordV3].self, from: data),
                !records.isEmpty
            else {
                continue
            }
            return records
        }
        return []
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []

        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        urls.append(
            repoRoot.appendingPathComponent(
                relativeSkillManifestPath,
                isDirectory: false
            )
        )

        let currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(
            currentDirectoryURL.appendingPathComponent(
                relativeSkillManifestPath,
                isDirectory: false
            )
        )

        if let resourceURL = Bundle.main.resourceURL {
            urls.append(
                resourceURL.appendingPathComponent(
                    "MagicianSkills/magician-skills.json",
                    isDirectory: false
                )
            )
            urls.append(
                resourceURL.appendingPathComponent(
                    "magician-skills.json",
                    isDirectory: false
                )
            )
        }

        let testBundle = Bundle(for: MagicianSkillBundleMarkerV3.self)
        if let resourceURL = testBundle.resourceURL {
            urls.append(
                resourceURL.appendingPathComponent(
                    "MagicianSkills/magician-skills.json",
                    isDirectory: false
                )
            )
            urls.append(
                resourceURL.appendingPathComponent(
                    "magician-skills.json",
                    isDirectory: false
                )
            )
        }
        return urls
    }
}

private final class MagicianSkillCatalogV3 {
    private(set) var manifests: [MagicianSkillManifestV3]
    private var map: [String: MagicianSkillManifestV3]

    init(enabledFeatures: Set<MagicianFeatureID>) {
        var entries = MagicianSkillManifestLoaderV3.loadEnabledManifests(
            enabledFeatures: enabledFeatures
        )
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

    // 一级目录：只给“域级”线索，避免把完整 skill 明细塞进主上下文。
    func domainTier1Summary() -> String {
        let grouped = Dictionary(grouping: manifests) { manifest in
            domainTier1Key(from: manifest.domain)
        }
        return grouped
            .sorted { $0.key < $1.key }
            .map { key, items in
                let samples = items
                    .map(\.id)
                    .sorted()
                    .prefix(2)
                    .joined(separator: ", ")
                if items.count > 2 {
                    return "\(key) | count=\(items.count) | sample=\(samples) ..."
                }
                return "\(key) | count=\(items.count) | sample=\(samples)"
            }
            .joined(separator: "\n")
    }

    // 搜索索引：按域分组并截断每组 skill 数量，减少 router 模型上下文体积。
    func searchIndexSummary(maxSkillIDsPerDomain: Int = 6) -> String {
        let grouped = Dictionary(grouping: manifests, by: \.domain)
        return grouped
            .sorted { $0.key < $1.key }
            .map { domain, items in
                let sortedIDs = items.map(\.id).sorted()
                let kept = Array(sortedIDs.prefix(maxSkillIDsPerDomain))
                if sortedIDs.count > kept.count {
                    return "\(domain): \(kept.joined(separator: ", ")) ... (+\(sortedIDs.count - kept.count))"
                }
                return "\(domain): \(kept.joined(separator: ", "))"
            }
            .joined(separator: "\n")
    }

    private func domainTier1Key(from domain: String) -> String {
        let parts = domain.split(separator: ".")
        if parts.count >= 2 {
            return "\(parts[0]).\(parts[1])"
        }
        return domain
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

// MARK: - Kernel Tooling + Router

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
        let rule = ruleSearch(query: query, catalog: catalog)
        let lexical = lexicalSearch(query: query, catalog: catalog)
        let model = await modelSearch(query: query, catalog: catalog)
        var scoreMap: [String: Double] = [:]
        for candidate in rule {
            scoreMap[candidate.skillID] = max(scoreMap[candidate.skillID] ?? 0, candidate.score)
        }
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

    private func ruleSearch(
        query: String,
        catalog: MagicianSkillCatalogV3
    ) -> [MagicianSkillSearchCandidateV3] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return []
        }

        var matchedIDs: [String] = []
        func appendIfExists(_ skillID: String?) {
            guard
                let skillID,
                catalog.manifest(for: skillID) != nil,
                !matchedIDs.contains(skillID)
            else {
                return
            }
            matchedIDs.append(skillID)
        }

        if
            containsAny(normalized, tokens: ["飞书", "feishu", "lark"])
                || FeishuCanonicalOperation.allCases.contains(where: {
                    normalized.contains($0.rawValue.lowercased())
                })
        {
            appendIfExists(FeishuCanonicalOperation.infer(from: normalized)?.rawValue)
        }

        if containsAny(normalized, tokens: ["音乐", "歌曲", "music", "播放", "暂停", "下一首", "上一首", "继续"]) {
            if containsAny(normalized, tokens: ["暂停", "pause", "停止播放", "停一下"]) {
                appendIfExists("apple.music.pause")
            } else if containsAny(normalized, tokens: ["下一首", "下一曲", "next", "skip"]) {
                appendIfExists("apple.music.next_track")
            } else if containsAny(normalized, tokens: ["上一首", "上一曲", "previous", "back"]) {
                appendIfExists("apple.music.previous_track")
            } else if containsAny(normalized, tokens: ["继续", "恢复", "resume", "继续播放"]) {
                appendIfExists("apple.music.resume")
            } else {
                let hasQueryHint = containsAny(
                    normalized,
                    tokens: ["《", "》", "歌单", "专辑", "歌手", "歌曲", "playlist", "album", "artist", " by ", "的"]
                ) || normalized.count >= 8
                appendIfExists(hasQueryHint ? "apple.music.play_query" : "apple.music.play")
            }
        }

        if containsAny(normalized, tokens: ["邮件", "mail", "email", "收件人", "主题", "抄送", "草稿"]) {
            if containsAny(normalized, tokens: ["发送", "发出", "send"]) && !containsAny(normalized, tokens: ["草稿", "draft"]) {
                appendIfExists("apple.mail.send")
            } else if containsAny(normalized, tokens: ["联系人", "找人", "收件人是谁", "resolve recipient"]) {
                appendIfExists("apple.mail.resolve_recipient")
            } else {
                appendIfExists("apple.mail.compose")
            }
        }

        if containsAny(normalized, tokens: ["日程", "会议", "calendar", "event", "行程", "安排", "提醒"]) {
            if containsAny(normalized, tokens: ["查询", "查找", "看看", "有没有", "find", "search", "list"]) {
                appendIfExists("apple.calendar.find_event")
            } else if containsAny(normalized, tokens: ["更新", "改到", "推迟", "提前", "调整", "变更", "update", "reschedule"]) {
                appendIfExists("apple.calendar.update_event")
            } else {
                appendIfExists("apple.calendar.create_event")
            }
        }

        if containsAny(normalized, tokens: ["备忘录", "note", "笔记"]) {
            if containsAny(normalized, tokens: ["追加", "补充", "加到", "append"]) {
                appendIfExists("apple.notes.append_note")
            } else if containsAny(normalized, tokens: ["查找", "查询", "搜索", "find", "search"]) {
                appendIfExists("apple.notes.find_note")
            } else {
                appendIfExists("apple.notes.create_note")
            }
        }

        if containsAny(normalized, tokens: ["翻译", "润色", "改写", "总结", "提炼", "rewrite", "summarize", "translate"]) {
            appendIfExists("text.transform")
        }
        if containsAny(normalized, tokens: ["终端", "命令行", "shell", "zsh", "bash", "执行命令", "run command", "运行命令"]) {
            appendIfExists("shell.command.run")
        }
        if matchedIDs.isEmpty {
            if looksLikeShellTask(normalized) {
                appendIfExists("shell.command.run")
            } else {
                appendIfExists("core.reason.respond")
            }
        }

        let base = 0.97
        return matchedIDs.enumerated().map { index, skillID in
            MagicianSkillSearchCandidateV3(
                skillID: skillID,
                score: max(0.6, base - (Double(index) * 0.08)),
                reason: "rule_match"
            )
        }
    }

    private func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
    }

    private func looksLikeShellTask(_ value: String) -> Bool {
        if containsAny(
            value,
            tokens: [
                "ls ", "pwd", "find ", "grep ", "rg ",
                "git ", "npm ", "pnpm ", "yarn ",
                "python ", "node ", "swift ", "xcodebuild",
                "chmod ", "chown ", "mkdir ", "cp ", "mv ", "cat "
            ]
        ) {
            return true
        }
        if value.contains("```") || value.contains("-la") || value.contains("--help") {
            return true
        }
        return false
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
        if output.isEmpty, catalog.manifest(for: "core.reason.respond") != nil {
            output.append(
                MagicianSkillSearchCandidateV3(
                    skillID: "core.reason.respond",
                    score: 0.25,
                    reason: "default_reasoner"
                )
            )
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
        规则：
        1) 只在需要外部动作时选择 apple.* 或 feishu_* skill。
        2) 纯文本理解、解释、翻译、总结优先选择 core.reason.respond 或 text.transform。
        3) 当步骤需要在本机终端执行命令时，选择 shell.command.run。
        不要输出其他文字。
        """
        let user = """
        user_query:
        \(query)

        skill_domain_index:
        \(catalog.searchIndexSummary(maxSkillIDsPerDomain: 6))
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
            var output: [String] = []
            for item in ids {
                guard let id = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
                    continue
                }
                guard catalog.manifest(for: id) != nil, !output.contains(id) else {
                    continue
                }
                output.append(id)
            }
            return output
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

// MARK: - Skill Runtime

@MainActor
private final class MagicianSkillRuntimeV3 {
    private let toolExecutor: any MagicianToolExecuting
    private let textBackend: MagicianAgentTextBackend
    private let llmClient: MagicianKernelLLMClientV3
    private let calendarStore = EKEventStore()

    init(
        toolExecutor: any MagicianToolExecuting,
        textBackend: MagicianAgentTextBackend,
        llmClient: MagicianKernelLLMClientV3
    ) {
        self.toolExecutor = toolExecutor
        self.textBackend = textBackend
        self.llmClient = llmClient
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
        if skillID == "core.reason.respond" {
            return try await coreReasonSkill(input: input, request: request, context: context)
        }
        if skillID == "text.transform" {
            return try await transformTextSkill(input: input, request: request)
        }
        if skillID == "shell.command.run" {
            return try await shellCommandSkill(input: input, request: request)
        }

        if skillID.hasPrefix("feishu_"), let operation = FeishuCanonicalOperation(rawValue: skillID) {
            var params = MagicianIntentParams.empty
            params.cliOperation = operation.rawValue
            if let args = input["arguments"] as? [String] {
                params.cliArguments = args
            }
            let baseCommand = stringValue(input["spoken_command"]) ?? request.command
            let previousOutput = stringValue(input["previous_output"])
            let command: String
            if let previousOutput, !previousOutput.isEmpty {
                command = "\(baseCommand)\n\n附加文本：\(previousOutput)"
            } else {
                command = baseCommand
            }
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
        params.mailBody = stringValue(input["body"])
            ?? stringValue(input["previous_output"])
            ?? request.selectionSnapshot?.selectedText
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
            ?? stringValue(input["previous_output"])
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

    private func coreReasonSkill(
        input: [String: Any],
        request: MagicianAgentRequest,
        context: MagicianKernelRuntimeContextV3
    ) async throws -> MagicianSkillInvokeResultV3 {
        let instruction = stringValue(input["instruction"])
            ?? stringValue(input["objective"])
            ?? request.command
        let previousOutput = stringValue(input["previous_output"])
            ?? context.stepRecords.compactMap(\.outputText).last
        let user = """
        instruction:
        \(instruction)

        command:
        \(request.command)

        previous_output:
        \(previousOutput ?? "")

        selected_text:
        \(request.selectionSnapshot?.selectedText ?? "")

        focus_app:
        \(request.focusContext.appName)
        """
        let system = """
        你是魔术先生的核心推理执行器。
        任务：仅用文本完成当前步骤，不调用外部系统动作。
        要求：
        1) 保持与用户目标一致。
        2) 输出直接可用的结果文本，不要解释流程。
        """
        let output = try await llmClient.generate(
            systemPrompt: system,
            userPrompt: user,
            temperature: 0.1,
            maxOutputTokens: 1_200
        )
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "核心推理步骤没有返回有效文本。",
                debugMessage: "core reason empty output",
                recoverAction: "retry_command"
            )
        }
        let observation = MagicianAgentObservation(
            verificationStatus: .verified,
            targetSummary: instruction,
            evidenceSummary: "core.reason.respond chars=\(normalized.count)"
        )
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .textTransform,
                userMessage: "核心推理已完成",
                outputText: normalized,
                historyDisplayText: "核心推理：\(summarizedHistoryText(normalized))",
                fallbackUsed: false,
                observation: observation
            ),
            skillID: "core.reason.respond",
            evidence: observation.evidenceSummary ?? "core.reason.respond"
        )
    }

    private func shellCommandSkill(
        input: [String: Any],
        request: MagicianAgentRequest
    ) async throws -> MagicianSkillInvokeResultV3 {
        let objective = stringValue(input["objective"]) ?? request.command
        let command = try await resolvedShellCommand(input: input, objective: objective, request: request)
        try validateShellCommandSafety(command)

        let timeout = max(5.0, min(180.0, Double(intValue(input["timeout_seconds"]) ?? 45)))
        let result = await runProcessWithTimeout(
            executablePath: "/bin/zsh",
            arguments: ["-lc", command],
            timeoutSeconds: timeout,
            maxOutputCharacters: 12_000
        )

        if result.exitCode != 0 {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "终端命令执行失败：\(result.detail)",
                debugMessage: "shell command failed: \(command) | exit=\(result.exitCode)",
                recoverAction: "retry_command"
            )
        }

        let output = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let normalizedOutput = output.isEmpty ? "(no output)" : output
        let observation = MagicianAgentObservation(
            verificationStatus: .verified,
            targetSummary: objective,
            evidenceSummary: "exit=0"
        )
        return MagicianSkillInvokeResultV3(
            execution: MagicianExecutionResult(
                intent: .textTransform,
                userMessage: "终端命令已执行",
                outputText: normalizedOutput,
                historyDisplayText: "shell: \(summarizedHistoryText(command, limit: 96))",
                fallbackUsed: false,
                observation: observation
            ),
            skillID: "shell.command.run",
            evidence: "exit=0"
        )
    }

    private func resolvedShellCommand(
        input: [String: Any],
        objective: String,
        request: MagicianAgentRequest
    ) async throws -> String {
        if let explicit = stringValue(input["command"])?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }

        let system = """
        你是终端命令生成器。请根据目标生成一条可直接执行的 macOS zsh 命令。
        仅输出 JSON：{"command":"..."}
        规则：
        1) 只输出一条命令，不要解释。
        2) 不要包含 sudo。
        3) 命令必须可在当前项目目录执行。
        """
        let user = """
        objective:
        \(objective)

        original_command:
        \(request.command)

        selected_text:
        \(request.selectionSnapshot?.selectedText ?? "")
        """
        let raw = try await llmClient.generate(
            systemPrompt: system,
            userPrompt: user,
            temperature: 0,
            maxOutputTokens: 220
        )
        guard
            let object = parseJSONObject(raw),
            let command = stringValue(object["command"])?.trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty
        else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "终端命令生成失败，请补充更具体的目标。",
                debugMessage: raw,
                recoverAction: "retry_command"
            )
        }
        return command
    }

    private func validateShellCommandSafety(_ command: String) throws {
        let lowered = command.lowercased()
        let blockedPatterns = [
            "rm -rf /",
            "sudo ",
            "shutdown",
            "reboot",
            "mkfs",
            "diskutil erasedisk",
            ":(){:|:&};:"
        ]
        if blockedPatterns.contains(where: { lowered.contains($0) }) {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "命令包含高风险操作，已拒绝执行。",
                debugMessage: "blocked shell command: \(command)",
                recoverAction: "retry_command"
            )
        }
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

private struct MagicianIntentPlanStepV3 {
    let id: String
    let objective: String
    let skillHint: String?
    let input: [String: Any]
}

private struct MagicianIntentPlanV3 {
    let goal: String
    var todo: [MagicianTodoItemV3]
    var steps: [MagicianIntentPlanStepV3]
}

private struct MagicianPostStepDecisionV3 {
    let isDone: Bool
    let finalMessage: String?
    let appendedStep: MagicianIntentPlanStepV3?
}

// MARK: - Agent Kernel Runtime

@MainActor
final class MagicianAgentRuntimeV3: MagicianAgentRunning {
    private let llmClient: MagicianKernelLLMClientV3
    private let skillRouter: MagicianSkillRouterV3
    private let skillRuntime: MagicianSkillRuntimeV3
    private let toolRegistry = MagicianToolRegistryV3()

    init(
        providerSettingsStore: ProviderSettingsStore,
        rewriteProviderRegistry: RewriteProviderRegistry,
        textOutputCoordinator: TextOutputCoordinator,
        skillRuleStore: SkillRuleStore,
        toolExecutor: any MagicianToolExecuting,
        llmProvider: any TextGenerationProvider = OpenAITextGenerationProvider()
    ) {
        let textBackend = MagicianAgentTextBackend(
            providerSettingsStore: providerSettingsStore,
            rewriteProviderRegistry: rewriteProviderRegistry,
            textOutputCoordinator: textOutputCoordinator,
            skillRuleStore: skillRuleStore
        )
        let llmClient = MagicianKernelLLMClientV3(
            providerSettingsStore: providerSettingsStore,
            provider: llmProvider
        )
        self.llmClient = llmClient
        self.skillRouter = MagicianSkillRouterV3(llmClient: llmClient)
        self.skillRuntime = MagicianSkillRuntimeV3(
            toolExecutor: toolExecutor,
            textBackend: textBackend,
            llmClient: llmClient
        )
        registerTools()
    }

    func run(
        request: MagicianAgentRequest,
        onEvent: ((MagicianAgentRuntimeEvent) -> Void)?
    ) async throws -> MagicianAgentRunOutcome {
        if !llmClient.isReadyForKernel() {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "CLI 文本模型不可用，请先完成配置。",
                debugMessage: "kernel llm not ready",
                recoverAction: "open_provider_settings"
            )
        }

        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .requestAccepted,
                state: .queued,
                message: "Agent 已启动。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )
        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .stateChanged,
                state: .understanding,
                message: "正在进行命令预处理。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )

        let normalizedCommand = try await preprocessCommand(request: request)
        let normalizedRequest = MagicianAgentRequest(
            traceID: request.traceID,
            command: normalizedCommand,
            selectionSnapshot: request.selectionSnapshot,
            focusContext: request.focusContext,
            enabledFeatures: request.enabledFeatures
        )

        let catalog = MagicianSkillCatalogV3(enabledFeatures: normalizedRequest.enabledFeatures)
        guard !catalog.manifests.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "未加载到可用 skill 清单，请检查本地 skill 目录。",
                debugMessage: "skill catalog empty",
                recoverAction: "retry_command"
            )
        }
        let context = MagicianKernelRuntimeContextV3(request: normalizedRequest, catalog: catalog)
        let sessionID = UUID().uuidString
        let runID = UUID().uuidString

        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .stateChanged,
                state: .planning,
                message: "正在生成结构化计划。",
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )

        var plan = try await buildIntentPlan(context: context)
        if plan.todo.isEmpty {
            plan.todo = plan.steps.enumerated().map { index, step in
                MagicianTodoItemV3(id: step.id.isEmpty ? String(index + 1) : step.id, text: step.objective, status: .pending)
            }
        }
        _ = try await executeKernelTool(
            .todoUpdate,
            input: ["items": serializeTodoItems(plan.todo)],
            context: context
        )

        onEvent?(
            MagicianAgentRuntimeEvent(
                name: .planReady,
                state: .planning,
                message: plan.steps.map(\.objective).joined(separator: " -> "),
                progressHint: SessionHUDProgressHint.workflowPreview
            )
        )

        var finalMessage = "已完成。"
        var stepCursor = 0
        while stepCursor < plan.steps.count, stepCursor < 14 {
            let currentStep = plan.steps[stepCursor]
            let totalStepsHint = max(plan.steps.count, 1)
            plan.todo = buildTodoState(base: plan.todo, currentIndex: stepCursor)
            _ = try await executeKernelTool(
                .todoUpdate,
                input: ["items": serializeTodoItems(plan.todo)],
                context: context
            )
            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stepStarted,
                    state: .executingStep,
                    message: "第\(stepCursor + 1)步：\(currentStep.objective)",
                    progressHint: SessionHUDProgressHint.workflowStep(index: stepCursor + 1, totalSteps: totalStepsHint),
                    stepIndex: stepCursor + 1,
                    totalSteps: totalStepsHint
                )
            )

            let searchOutcome = try await executeKernelTool(
                .skillSearch,
                input: [
                    "query": "\(currentStep.objective)\n\(context.request.command)",
                    "count": 6
                ],
                context: context
            )
            let searchedSkillIDs = parseSkillIDs(fromSearchOutput: searchOutcome.outputText)
            var candidateSkillIDs: [String] = []
            if let hinted = currentStep.skillHint, context.catalog.manifest(for: hinted) != nil {
                candidateSkillIDs.append(hinted)
            }
            for skillID in searchedSkillIDs where !candidateSkillIDs.contains(skillID) {
                candidateSkillIDs.append(skillID)
            }
            if candidateSkillIDs.isEmpty {
                let fallbackCandidates = await skillRouter.search(
                    query: currentStep.objective,
                    catalog: context.catalog,
                    preferredCount: 3
                )
                    .map(\.skillID)
                for skillID in fallbackCandidates where !candidateSkillIDs.contains(skillID) {
                    candidateSkillIDs.append(skillID)
                }
            }
            if candidateSkillIDs.isEmpty {
                let probeText = "\(currentStep.objective)\n\(context.request.command)".lowercased()
                if
                    runtimeLooksLikeShellTask(probeText),
                    context.catalog.manifest(for: "shell.command.run") != nil
                {
                    candidateSkillIDs.append("shell.command.run")
                } else if context.catalog.manifest(for: "core.reason.respond") != nil {
                    candidateSkillIDs.append("core.reason.respond")
                }
            }

            guard let selectedSkillID = candidateSkillIDs.first else {
                throw MagicianError(
                    code: .intentParseFailed,
                    userMessage: "当前命令找不到可执行 skill。",
                    debugMessage: "skill candidates empty",
                    recoverAction: "retry_command"
                )
            }

            _ = try await executeKernelTool(
                .skillLoadMin,
                input: ["skill_ids": Array(candidateSkillIDs.prefix(3))],
                context: context
            )

            let invokeOutcome = try await executeKernelTool(
                .skillInvoke,
                input: [
                    "skill_id": selectedSkillID,
                    "input": enrichedStepInput(currentStep.input, context: context, objective: currentStep.objective)
                ],
                context: context
            )

            let verifyOutcome = try await executeKernelTool(
                .verifyResult,
                input: ["target": currentStep.objective],
                context: context
            )

            onEvent?(
                MagicianAgentRuntimeEvent(
                    name: .stepFinished,
                    state: .observing,
                    message: "\(invokeOutcome.message) | \(verifyOutcome.message)",
                    progressHint: SessionHUDProgressHint.workflowStep(index: stepCursor + 1, totalSteps: totalStepsHint),
                    stepIndex: stepCursor + 1,
                    totalSteps: totalStepsHint
                )
            )

            let postDecision = try await decidePostStep(
                context: context,
                plan: plan,
                currentStep: currentStep,
                currentIndex: stepCursor
            )
            if let final = postDecision.finalMessage, !final.isEmpty {
                finalMessage = final
            }
            if let appendedStep = postDecision.appendedStep, plan.steps.count < 14 {
                plan.steps.append(appendedStep)
                plan.todo.append(
                    MagicianTodoItemV3(
                        id: appendedStep.id,
                        text: appendedStep.objective,
                        status: .pending
                    )
                )
            }
            plan.todo = buildTodoState(base: plan.todo, currentIndex: stepCursor + 1)
            _ = try await executeKernelTool(
                .todoUpdate,
                input: ["items": serializeTodoItems(plan.todo)],
                context: context
            )
            if postDecision.isDone {
                break
            }
            stepCursor += 1
        }

        if context.stepRecords.isEmpty {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "本次没有产出可执行结果。",
                debugMessage: "empty step records",
                recoverAction: "retry_command"
            )
        }

        let lastOutput = context.stepRecords.compactMap(\.outputText).last ?? context.lastSkillResult?.execution.outputText
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
            goalSummary: plan.goal,
            finalStatusMessage: finalMessage,
            finalOutputText: lastOutput,
            displayText: "Agent: \(context.stepRecords.map { $0.featureID.displayName }.joined(separator: " -> "))",
            steps: context.stepRecords,
            evidenceSummary: evidence
        )
    }

    private func preprocessCommand(request: MagicianAgentRequest) async throws -> String {
        let system = """
        你是 Agent 命令预处理模型。
        任务：把语音转写命令整理成更清晰的一句可执行命令。
        规则：
        1) 保持原意，不要新增目标。
        2) 保留 URL、邮箱、ID、token。
        3) 仅输出 JSON：{"command":"..."}
        """
        let user = """
        raw_command:
        \(request.command)

        selected_text:
        \(request.selectionSnapshot?.selectedText ?? "")

        focus_app:
        \(request.focusContext.appName)
        """
        let raw = try await llmClient.generate(
            systemPrompt: system,
            userPrompt: user,
            temperature: 0,
            maxOutputTokens: 500
        )
        guard
            let object = parseJSONObject(raw),
            let command = stringValue(object["command"]),
            !command.isEmpty
        else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "命令预处理失败，请重试。",
                debugMessage: raw,
                recoverAction: "retry_command"
            )
        }
        return command
    }

    private func buildIntentPlan(context: MagicianKernelRuntimeContextV3) async throws -> MagicianIntentPlanV3 {
        let system = """
        你是 Agent 意图规划模型。
        你必须输出结构化计划，并把复杂任务拆成原子步骤。
        只输出 JSON：
        {
          "goal":"string",
          "todo":[{"id":"1","text":"...","status":"pending"}],
          "steps":[{"id":"step-1","objective":"...","skill_id":"optional","input":{}}]
        }
        约束：
        1) steps 必须按执行顺序排列。
        2) 每个 step 只做一件事。
        3) 纯文本理解/解释/翻译/总结优先使用 skill_id: "core.reason.respond"。
        4) 当步骤需要写入编辑器或剪贴板时，使用 skill_id: "text.transform"。
        5) 只有外部动作才使用 apple.* 或 feishu_* skill。
        6) status 仅允许 pending / in_progress / completed。
        7) 如果步骤无法匹配现成 skill，且本质是本机命令执行，使用 skill_id: "shell.command.run"，并在 input.command 给出完整命令。
        """
        let user = """
        command:
        \(context.request.command)

        selected_text:
        \(context.request.selectionSnapshot?.selectedText ?? "")

        focus_app:
        \(context.request.focusContext.appName)

        enabled_skill_domain_index_level_1:
        \(context.catalog.domainTier1Summary())
        """
        let raw = try await llmClient.generate(
            systemPrompt: system,
            userPrompt: user,
            temperature: 0.1,
            maxOutputTokens: 1_500
        )
        guard let object = parseJSONObject(raw) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "计划生成失败，请重试。",
                debugMessage: raw,
                recoverAction: "retry_command"
            )
        }
        let goal = stringValue(object["goal"]) ?? summarizedHistoryText(context.request.command, limit: 48)
        var steps: [MagicianIntentPlanStepV3] = []
        if let stepObjects = object["steps"] as? [Any] {
            for (index, item) in stepObjects.enumerated() {
                guard let map = item as? [String: Any] else {
                    continue
                }
                let objective = stringValue(map["objective"]) ?? ""
                guard !objective.isEmpty else {
                    continue
                }
                let id = stringValue(map["id"]) ?? "step-\(index + 1)"
                let skillHint = stringValue(map["skill_id"])
                let input = map["input"] as? [String: Any] ?? [:]
                steps.append(
                    MagicianIntentPlanStepV3(
                        id: id,
                        objective: objective,
                        skillHint: skillHint,
                        input: input
                    )
                )
            }
        }
        guard !steps.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "计划生成失败，请重试。",
                debugMessage: "plan steps empty",
                recoverAction: "retry_command"
            )
        }
        let todo = parseTodoItems(object["todo"])
        return MagicianIntentPlanV3(
            goal: goal,
            todo: todo,
            steps: Array(steps.prefix(14))
        )
    }

    private func decidePostStep(
        context: MagicianKernelRuntimeContextV3,
        plan: MagicianIntentPlanV3,
        currentStep: MagicianIntentPlanStepV3,
        currentIndex: Int
    ) async throws -> MagicianPostStepDecisionV3 {
        let transcript = context.transcript.suffix(8).joined(separator: "\n")
        let system = """
        你是 Agent 意图模型，负责基于步骤证据判断是否继续执行。
        只输出 JSON：
        {
          "decision":"continue|done",
          "final_message":"optional",
          "append_step":{"id":"step-x","objective":"...","skill_id":"optional","input":{}}
        }
        append_step 仅在需要新增一步时返回，否则填 null。
        """
        let user = """
        goal:
        \(plan.goal)

        current_step_index:
        \(currentIndex + 1)

        current_step_objective:
        \(currentStep.objective)

        todo_state:
        \(context.todoStore.render())

        recent_transcript:
        \(transcript)
        """
        let raw = try await llmClient.generate(
            systemPrompt: system,
            userPrompt: user,
            temperature: 0,
            maxOutputTokens: 700
        )
        guard let object = parseJSONObject(raw) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "步骤决策失败，请重试。",
                debugMessage: raw,
                recoverAction: "retry_command"
            )
        }
        let decision = (stringValue(object["decision"]) ?? "continue").lowercased()
        let finalMessage = stringValue(object["final_message"])
        var appendedStep: MagicianIntentPlanStepV3?
        if
            let appendMap = object["append_step"] as? [String: Any],
            let objective = stringValue(appendMap["objective"]),
            !objective.isEmpty
        {
            let stepID = stringValue(appendMap["id"]) ?? "step-extra-\(UUID().uuidString.prefix(6))"
            appendedStep = MagicianIntentPlanStepV3(
                id: stepID,
                objective: objective,
                skillHint: stringValue(appendMap["skill_id"]),
                input: appendMap["input"] as? [String: Any] ?? [:]
            )
        }
        return MagicianPostStepDecisionV3(
            isDone: decision == "done",
            finalMessage: finalMessage,
            appendedStep: appendedStep
        )
    }

    private func executeKernelTool(
        _ tool: MagicianKernelToolNameV3,
        input: [String: Any],
        context: MagicianKernelRuntimeContextV3
    ) async throws -> MagicianKernelToolOutcomeV3 {
        let outcome = try await toolRegistry.invoke(
            tool.rawValue,
            input: input,
            context: context
        )
        context.transcript.append(
            """
            tool=\(tool.rawValue)
            message=\(outcome.message)
            evidence=\(outcome.evidence ?? "")
            """
        )
        if tool == .todoUpdate {
            context.roundsSinceTodo = 0
        } else {
            context.roundsSinceTodo += 1
        }
        if let featureID = outcome.featureID {
            context.stepRecords.append(
                MagicianAgentStepRecord(
                    id: "step-\(context.stepRecords.count + 1)",
                    featureID: featureID,
                    instruction: tool.rawValue,
                    userMessage: outcome.message,
                    outputText: outcome.outputText,
                    observation: outcome.observation
                )
            )
        }
        return outcome
    }

    private func serializeTodoItems(_ items: [MagicianTodoItemV3]) -> [[String: Any]] {
        items.map {
            [
                "id": $0.id,
                "text": $0.text,
                "status": $0.status.rawValue
            ]
        }
    }

    private func buildTodoState(base: [MagicianTodoItemV3], currentIndex: Int) -> [MagicianTodoItemV3] {
        guard !base.isEmpty else {
            return []
        }
        return base.enumerated().map { index, item in
            let status: MagicianTodoStatusV3
            if index < currentIndex {
                status = .completed
            } else if index == currentIndex {
                status = .inProgress
            } else {
                status = .pending
            }
            return MagicianTodoItemV3(
                id: item.id,
                text: item.text,
                status: status
            )
        }
    }

    private func enrichedStepInput(
        _ base: [String: Any],
        context: MagicianKernelRuntimeContextV3,
        objective: String
    ) -> [String: Any] {
        var input = base
        if input["objective"] == nil {
            input["objective"] = objective
        }
        if input["spoken_command"] == nil {
            input["spoken_command"] = context.request.command
        }
        let previousOutput = context.lastSkillResult?.execution.outputText
            ?? context.stepRecords.compactMap(\.outputText).last
        if let previousOutput, !previousOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if input["previous_output"] == nil {
                input["previous_output"] = previousOutput
            }
        }
        return input
    }

    private func parseSkillIDs(fromSearchOutput output: String?) -> [String] {
        guard let output, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var ids: [String] = []
        for line in output.split(separator: "\n") {
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                continue
            }
            let skillID = raw
                .components(separatedBy: "|")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !skillID.isEmpty, !ids.contains(skillID) else {
                continue
            }
            ids.append(skillID)
        }
        return ids
    }

    private func runtimeLooksLikeShellTask(_ text: String) -> Bool {
        let tokens = [
            "终端", "命令行", "shell", "zsh", "bash",
            "ls ", "pwd", "git ", "npm ", "pnpm ", "yarn ",
            "python ", "node ", "swift ", "xcodebuild",
            "find ", "grep ", "rg "
        ]
        return tokens.contains { text.contains($0) }
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
            context.loadedCards.removeAll(keepingCapacity: true)
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
            let explicitSkillID = stringValue(input["skill_id"])
            let stepObjective = stringValue((input["input"] as? [String: Any])?["objective"]) ?? context.request.command
            let routedSkillID = await self.skillRouter.search(
                query: stepObjective,
                catalog: context.catalog,
                preferredCount: 1
            )
                .first?
                .skillID
            let coreSkillID = context.catalog.manifest(for: "core.reason.respond") != nil ? "core.reason.respond" : nil
            let skillID = explicitSkillID ?? routedSkillID ?? coreSkillID ?? ""
            guard !skillID.isEmpty else {
                throw MagicianError(
                    code: .intentParseFailed,
                    userMessage: "当前没有可执行动作，请换个说法。",
                    debugMessage: "skill unresolved after fallback routing",
                    recoverAction: "retry_command"
                )
            }

            let skillInput = (input["input"] as? [String: Any]) ?? [:]
            var finalError: Error?
            let fallbackCandidates = await self.skillRouter.search(
                query: stepObjective,
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
                    context.loadedCards.removeAll(keepingCapacity: true)
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
            context.loadedCards.removeAll(keepingCapacity: true)
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
}

// MARK: - Shared Parsing Helpers

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
