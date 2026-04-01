import Foundation

struct V4PlannerLLM: V4Planner, @unchecked Sendable {
    struct ModelContext: Sendable {
        let configuration: TextGenerationProviderConfiguration
        let apiKey: String
    }

    typealias ModelResolver = @Sendable (V4RunRequest) async throws -> ModelContext?

    private let generationProvider: any TextGenerationProvider
    private let fallbackPlanner: any V4Planner
    private let modelResolver: ModelResolver

    init(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        fallbackPlanner: any V4Planner = V4PlannerRuleBased(),
        modelResolver: ModelResolver? = nil
    ) {
        self.generationProvider = generationProvider
        self.fallbackPlanner = fallbackPlanner
        if let modelResolver {
            self.modelResolver = modelResolver
        } else {
            self.modelResolver = { request in
                guard let modelSlotManager else {
                    return nil
                }

                let endpoint = if let resolved = request.modelSlots?.endpoint(for: .agent) {
                    resolved
                } else {
                    try await modelSlotManager.resolve(.agent)
                }
                let configuration = try Self.makeConfiguration(from: endpoint)
                let apiKey = try await modelSlotManager.loadAPIKey(for: .agent)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !configuration.providerType.requiresAPIKey || !apiKey.isEmpty else {
                    return nil
                }
                return ModelContext(configuration: configuration, apiKey: apiKey)
            }
        }
    }

    func plan(for request: V4RunRequest) async throws -> V4Plan {
        let trimmedInput = request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return try await fallbackPlanner.plan(for: request)
        }

        guard let modelContext = try await modelResolver(request) else {
            return try await fallbackPlanner.plan(for: request)
        }

        let systemPrompt = plannerSystemPrompt(using: request.promptStack)
        let userPrompt = plannerUserPrompt(for: request)

        do {
            let generation = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    temperature: 0.1,
                    maxOutputTokens: 500
                ),
                configuration: modelContext.configuration,
                apiKey: modelContext.apiKey
            )
            return try decodedPlan(
                from: generation.outputText,
                request: request
            )
        } catch {
            return try await fallbackPlanner.plan(for: request)
        }
    }

    private func plannerSystemPrompt(using promptStack: V4PromptStack?) -> String {
        let plannerRules = """
        你是 PulseType V4 的 planner。你的任务不是直接输出结果，而是判断当前这一步最该做什么。

        只允许输出一个 JSON object，不要输出 Markdown，不要解释。

        你每一轮只能做三种事之一：
        1. 产出下一步：{"action":"step","step":{"toolName":"...","title":"...","inputSummary":"..."}}
        2. 任务已完成：{"action":"finish","message":"..."}
        3. 信息不足或任务冲突：{"action":"ask_user","message":"..."} 或 {"action":"fail","message":"..."}

        规则：
        - 只规划下一步，不要一次规划完整长链。
        - 已经完成的 step 不要重复做，除非上一步失败且明确需要重试。
        - 如果用户想“整理后再发邮件 / 记备忘录 / 建日程”，优先先走 text.transform，再进入外部 tool。
        - 如果当前已有一段整理好的 latestOutput，就优先拿它进入 mail / notes / calendar，而不是再重复改写。
        - 如果时间、对象、目标明显不够，优先 ask_user，不要硬猜。
        - 如果一句话混了互相独立的多个外部动作，也优先 ask_user。
        - 如果最新一步已经满足用户目标，直接 finish。

        可用 tool：
        - text.transform: 把当前文本按指令改写、整理、提炼、翻译。
        - apple.mail.compose: 写邮件、发邮件、生成草稿。
        - apple.notes.create: 新建备忘录。
        - apple.calendar.create: 新建 Calendar 日程。
        - apple.music.control: 打开音乐、播放、暂停、切歌。
        - feishu.cli: 飞书相关动作。
        - time_machine.create: 记录一条本地时光机项目。
        - time_machine.remind: 建本地提醒。
        """

        let promptLayers = [
            promptStack?.finalSystemPrompt.trimmedNilIfEmpty,
            promptStack?.finalGuidancePrompt.trimmedNilIfEmpty,
            plannerRules
        ].compactMap { $0 }

        return promptLayers.joined(separator: "\n\n")
    }

    private func plannerUserPrompt(for request: V4RunRequest) -> String {
        let completedSteps = request.stepRecords.enumerated().map { index, step in
            let status = step.status.rawValue
            let toolName = step.toolName ?? "text.transform"
            let input = step.inputSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = step.outputSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(index + 1). [\(status)] \(toolName) | title=\(step.title) | input=\(input) | output=\(output)"
        }

        let latestOutput = request.stepRecords.reversed()
            .compactMap(\.outputSummary)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return """
        当前任务：
        \(request.goalSummary)

        用户原始命令：
        \(request.inputText)

        当前选中文本：
        \(request.selectionText?.trimmedNilIfEmpty ?? "(none)")

        当前 App：
        \(request.appName?.trimmedNilIfEmpty ?? "(unknown)") | \(request.bundleID?.trimmedNilIfEmpty ?? "(unknown)")

        latestOutput：
        \(latestOutput.isEmpty ? "(none)" : latestOutput)

        已完成 steps：
        \(completedSteps.isEmpty ? "(none)" : completedSteps.joined(separator: "\n"))

        只输出 JSON。
        """
    }

    private func decodedPlan(
        from rawOutput: String,
        request: V4RunRequest
    ) throws -> V4Plan {
        let candidate = try extractJSONCandidate(from: rawOutput)
        let data = Data(candidate.utf8)
        let payload = try JSONDecoder().decode(PlannerResponse.self, from: data)

        switch payload.action {
        case .step:
            guard let stepPayload = payload.step else {
                throw PlannerDecodeError.invalidPayload
            }
            let toolName = stepPayload.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.allowedToolNames.contains(toolName) else {
                throw PlannerDecodeError.invalidToolName
            }
            let title = stepPayload.title?.trimmedNilIfEmpty ?? Self.defaultTitle(for: toolName)
            let inputSummary = stepPayload.inputSummary?.trimmedNilIfEmpty
                ?? request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            return V4Plan(
                steps: [
                    V4StepRecord(
                        traceID: request.traceID,
                        lane: request.lane,
                        goalSummary: request.goalSummary,
                        title: title,
                        status: .queued,
                        toolName: toolName,
                        inputSummary: summarized(inputSummary)
                    )
                ]
            )

        case .finish, .askUser, .fail:
            return V4Plan(
                steps: [],
                terminalDecision: V4LoopDecision(
                    action: payload.action.loopDecisionAction,
                    message: payload.message?.trimmedNilIfEmpty ?? Self.defaultMessage(for: payload.action),
                    failureCode: payload.action == .fail ? .invalidRequest : nil
                )
            )
        }
    }

    private func extractJSONCandidate(from rawOutput: String) throws -> String {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerDecodeError.empty
        }

        if trimmed.hasPrefix("```"), let fenced = extractFencedJSON(from: trimmed) {
            return fenced
        }

        guard
            let firstBrace = trimmed.firstIndex(of: "{"),
            let lastBrace = trimmed.lastIndex(of: "}")
        else {
            throw PlannerDecodeError.invalidPayload
        }

        return String(trimmed[firstBrace...lastBrace])
    }

    private func extractFencedJSON(from value: String) -> String? {
        let lines = value.components(separatedBy: .newlines)
        guard lines.count >= 3 else {
            return nil
        }

        var body = lines
        if body.first?.hasPrefix("```") == true {
            body.removeFirst()
        }
        if body.last?.hasPrefix("```") == true {
            body.removeLast()
        }
        let candidate = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private func summarized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 160 else {
            return trimmed
        }
        return String(trimmed.prefix(157)) + "..."
    }

    private static func makeConfiguration(from endpoint: V4ModelEndpoint) throws -> TextGenerationProviderConfiguration {
        guard let baseURL = URL(string: endpoint.baseURLString) else {
            throw V4ModelSlotResolutionError(
                slot: endpoint.slot,
                code: .invalidConfiguration,
                message: "接口地址（Base URL）无效。",
                sourceConfigurationKey: endpoint.sourceConfigurationKey,
                providerIdentifier: endpoint.providerIdentifier
            )
        }
        return TextGenerationProviderConfiguration(
            profileID: endpoint.credentialRef?.rawValue ?? endpoint.sourceConfigurationKey,
            providerType: endpoint.providerType,
            providerName: endpoint.providerDisplayName,
            modelName: endpoint.modelName,
            baseURL: baseURL
        )
    }

    private static func defaultTitle(for toolName: String) -> String {
        switch toolName {
        case "text.transform":
            return "文字处理"
        case "apple.mail.compose":
            return "整理邮件"
        case "apple.notes.create":
            return "写入备忘录"
        case "apple.calendar.create":
            return "创建日程"
        case "apple.music.control":
            return "控制音乐"
        case "feishu.cli":
            return "执行飞书命令"
        case "time_machine.create":
            return "记录到时光机"
        case "time_machine.remind":
            return "记录并提醒"
        default:
            return "执行动作"
        }
    }

    private static func defaultMessage(for action: PlannerAction) -> String {
        switch action {
        case .finish:
            return "已完成当前任务。"
        case .askUser:
            return "还缺少关键信息。"
        case .fail:
            return "当前任务没法继续执行。"
        case .step:
            return "继续执行下一步。"
        }
    }

    private static let allowedToolNames: Set<String> = [
        "text.transform",
        "apple.mail.compose",
        "apple.notes.create",
        "apple.calendar.create",
        "apple.music.control",
        "feishu.cli",
        "time_machine.create",
        "time_machine.remind"
    ]
}

private enum PlannerDecodeError: Error {
    case empty
    case invalidPayload
    case invalidToolName
}

private enum PlannerAction: String, Decodable {
    case step
    case finish
    case askUser = "ask_user"
    case fail

    var loopDecisionAction: V4LoopDecisionAction {
        switch self {
        case .step:
            return .continue
        case .finish:
            return .finish
        case .askUser:
            return .askUser
        case .fail:
            return .fail
        }
    }
}

private struct PlannerResponse: Decodable {
    struct Step: Decodable {
        let toolName: String
        let title: String?
        let inputSummary: String?
    }

    let action: PlannerAction
    let message: String?
    let step: Step?
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
