import Foundation

protocol MagicianLaneRouting: Sendable {
    func decide(
        command: String,
        selectionSnapshot: FocusedSelectionSnapshot?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async -> MagicianLaneDecision
}

struct MagicianSemanticLaneRouter: MagicianLaneRouting, @unchecked Sendable {
    struct ModelContext: Sendable {
        let configuration: TextGenerationProviderConfiguration
        let apiKey: String
    }

    typealias ModelResolver = @Sendable () async throws -> ModelContext?

    private let generationProvider: any TextGenerationProvider
    private let modelResolver: ModelResolver

    init(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        modelResolver: ModelResolver? = nil
    ) {
        self.generationProvider = generationProvider
        if let modelResolver {
            self.modelResolver = modelResolver
        } else {
            self.modelResolver = {
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    return nil
                }
                guard let modelSlotManager else {
                    return nil
                }
                let endpoint = try await modelSlotManager.resolve(.agent)
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

    func decide(
        command: String,
        selectionSnapshot: FocusedSelectionSnapshot?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async -> MagicianLaneDecision {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return MagicianLaneDecision(
                lane: .nativeFast,
                reason: "semantic_empty_command",
                userMessage: nil,
                selectionMode: .none
            )
        }
        guard let modelContext = try? await modelResolver() else {
            return MagicianLaneDecision(
                lane: .agent,
                reason: "semantic_router_no_model",
                userMessage: nil,
                selectionMode: .optional
            )
        }

        do {
            let generation = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt(
                        command: trimmedCommand,
                        selectionSnapshot: selectionSnapshot,
                        enabledFeatures: enabledFeatures
                    ),
                    temperature: 0,
                    maxOutputTokens: 220
                ),
                configuration: modelContext.configuration,
                apiKey: modelContext.apiKey
            )
            guard let parsed = try parseLaneResponse(from: generation.outputText) else {
                return MagicianLaneDecision(
                    lane: .agent,
                    reason: "semantic_router_invalid_output",
                    userMessage: nil,
                    selectionMode: .optional
                )
            }
            return parsed.toDecision()
        } catch {
            return MagicianLaneDecision(
                lane: .agent,
                reason: "semantic_router_error",
                userMessage: nil,
                selectionMode: .optional
            )
        }
    }

    private var systemPrompt: String {
        """
        你是 PulseType 的入口语义路由器。你只做一个动作：判定 lane。

        只输出 JSON，不要输出解释，不要 Markdown。

        可选 lane：
        - native_fast
        - agent

        输出格式：
        {"lane":"native_fast|agent","selection_mode":"none|optional|required","reason":"...","user_message":"..."}

        规则：
        - 语义优先，不要依赖关键词硬匹配。
        - 如果一句话包含多个外部动作或复杂多步骤自动化，统一输出 agent。
        - 如果是飞书、多步骤自动化、调研后执行外部动作，输出 agent。
        - 纯文本改写、单一原生动作可走 native_fast。
        - selection_mode 判定：
          - required：命令核心依赖“当前选中的文本”，没有选中就无法完成（如“把选中的内容翻译/总结/改写/提炼”）。
          - none：命令不依赖当前选中（如音乐控制、发邮件、创建日程、纯口述任务）。
          - optional：有选中更好但不是必须。
        - user_message 可留空。
        """
    }

    private func userPrompt(
        command: String,
        selectionSnapshot: FocusedSelectionSnapshot?,
        enabledFeatures: Set<MagicianFeatureID>
    ) -> String {
        let featureList = enabledFeatures
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let selectionText = selectionSnapshot?.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        command:
        \(command)

        has_selection:
        \(selectionText?.isEmpty == false ? "true" : "false")

        selection_text:
        \(selectionText?.isEmpty == false ? selectionText! : "(none)")

        enabled_features:
        \(featureList.isEmpty ? "(none)" : featureList)
        """
    }

    private func parseLaneResponse(from rawOutput: String) throws -> LaneResponse? {
        let candidate = try extractJSONCandidate(from: rawOutput)
        let data = Data(candidate.utf8)
        return try JSONDecoder().decode(LaneResponse.self, from: data)
    }

    private func extractJSONCandidate(from rawOutput: String) throws -> String {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LaneRouterDecodeError.invalidPayload
        }

        if trimmed.hasPrefix("```"), let fenced = extractFencedJSON(from: trimmed) {
            return fenced
        }

        guard
            let firstBrace = trimmed.firstIndex(of: "{"),
            let lastBrace = trimmed.lastIndex(of: "}")
        else {
            throw LaneRouterDecodeError.invalidPayload
        }
        return String(trimmed[firstBrace...lastBrace])
    }

    private func extractFencedJSON(from value: String) -> String? {
        var lines = value.components(separatedBy: .newlines)
        guard lines.count >= 3 else {
            return nil
        }
        if lines.first?.hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.hasPrefix("```") == true {
            lines.removeLast()
        }
        let candidate = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }

    private static func makeConfiguration(from endpoint: V4ModelEndpoint) throws -> TextGenerationProviderConfiguration {
        guard let baseURL = URL(string: endpoint.baseURLString) else {
            throw V4ModelSlotResolutionError(
                slot: endpoint.slot,
                code: .invalidConfiguration,
                message: "lane 路由模型配置无效。",
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
}

private enum SemanticLane: String, Decodable {
    case nativeFast = "native_fast"
    case agent
    case unsupportedMixedExternal = "unsupported_mixed_external"
}

private enum SemanticSelectionMode: String, Decodable {
    case none
    case optional
    case required

    var value: MagicianSelectionMode {
        switch self {
        case .none:
            return .none
        case .optional:
            return .optional
        case .required:
            return .required
        }
    }
}

private struct LaneResponse: Decodable {
    let lane: SemanticLane
    let selectionMode: SemanticSelectionMode?
    let reason: String?
    let userMessage: String?

    enum CodingKeys: String, CodingKey {
        case lane
        case selectionMode = "selection_mode"
        case reason
        case userMessage = "user_message"
    }

    func toDecision() -> MagicianLaneDecision {
        let resolvedSelectionMode = selectionMode?.value ?? .optional
        switch lane {
        case .nativeFast:
            return MagicianLaneDecision(
                lane: .nativeFast,
                reason: reason?.trimmedNilIfEmpty ?? "semantic_native_fast",
                userMessage: nil,
                selectionMode: resolvedSelectionMode
            )
        case .agent:
            return MagicianLaneDecision(
                lane: .agent,
                reason: reason?.trimmedNilIfEmpty ?? "semantic_agent",
                userMessage: nil,
                selectionMode: resolvedSelectionMode
            )
        case .unsupportedMixedExternal:
            return MagicianLaneDecision(
                lane: .agent,
                reason: reason?.trimmedNilIfEmpty ?? "semantic_unsupported_mixed_external",
                userMessage: nil,
                selectionMode: .optional
            )
        }
    }
}

private enum LaneRouterDecodeError: Error {
    case invalidPayload
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
