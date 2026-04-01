import Foundation

final class V4TextTransformTool: V4Tool, @unchecked Sendable {
    let spec = V4ToolSpec(
        toolName: "text.transform",
        displayName: "文字处理",
        summary: "按 instruction 处理输入文本，返回文本结果。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "text", kind: .string, summary: "原始文本"),
                V4ToolInputField(name: "instruction", kind: .string, summary: "处理指令")
            ]
        ),
        requiresPermission: false,
        permissionScope: nil,
        isConcurrencySafe: true,
        mutatesUserData: false,
        supportsStreamingResults: false
    )

    private let modelSlotManager: V4ModelSlotManager?
    private let generationProvider: any TextGenerationProvider
    private let executeHandler: (@Sendable (String, String) async throws -> V4ToolExecutionOutput)?

    init(
        modelSlotManager: V4ModelSlotManager? = nil,
        generationProvider: any TextGenerationProvider,
        executeHandler: (@Sendable (String, String) async throws -> V4ToolExecutionOutput)? = nil
    ) {
        self.modelSlotManager = modelSlotManager
        self.generationProvider = generationProvider
        self.executeHandler = executeHandler
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let text = arguments.string(for: "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let instruction = arguments.string(for: "instruction")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if text.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`text` 不能为空。",
                messageForDebug: "text empty"
            )
        }
        if instruction.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`instruction` 不能为空。",
                messageForDebug: "instruction empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let text = arguments.string(for: "text") ?? ""
        let instruction = arguments.string(for: "instruction") ?? ""

        if let executeHandler {
            return try await executeHandler(text, instruction)
        }

        guard let modelSlotManager else {
            let payload = V4ToolValue.object(
                [
                    "mode": .string("local_fallback"),
                    "instruction": .string(instruction),
                    "text": .string(text)
                ]
            )
            return V4ToolExecutionOutput(
                outputText: text,
                evidenceSummary: "text.transform fallback=no_provider_store",
                rawPayload: payload
            )
        }

        let configuration: TextGenerationProviderConfiguration
        let apiKey: String
        do {
            let endpoint = if let resolved = context.request.modelSlots?.endpoint(for: .text) {
                resolved
            } else {
                try await modelSlotManager.resolve(.text)
            }
            configuration = try makeConfiguration(from: endpoint)
            apiKey = try await modelSlotManager.loadAPIKey(for: .text)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch let error as V4ModelSlotResolutionError {
            throw V4ToolError(
                code: .modelUnavailable,
                toolID: spec.toolID,
                messageForUser: "文本模型槽位不可用：\(error.message)",
                messageForDebug: "\(error.code.rawValue) source=\(error.sourceConfigurationKey)",
                recoverAction: "check_text_provider",
                isRetryable: false
            )
        } catch {
            throw V4ToolError(
                code: .toolExecutionFailed,
                toolID: spec.toolID,
                messageForUser: "读取文本模型配置失败，请稍后再试。",
                messageForDebug: String(describing: error),
                recoverAction: "check_text_provider",
                isRetryable: false
            )
        }

        guard !configuration.providerType.requiresAPIKey || !apiKey.isEmpty else {
            throw V4ToolError(
                code: .modelUnavailable,
                toolID: spec.toolID,
                messageForUser: "当前没有可用的文本模型 API key，请先在设置里配置。",
                messageForDebug: "rewrite provider api key missing",
                recoverAction: "open_provider_settings",
                isRetryable: false
            )
        }

        let promptStack = context.request.promptStack
        let fallbackSystemPrompt = "你是 PulseType 的文字处理工具。只输出处理后的文本，不要解释。"
        let fallbackUserPrompt = """
        指令：
        \(instruction)

        原文：
        \(text)
        """
        let systemPrompt = [promptStack?.finalSystemPrompt, promptStack?.finalGuidancePrompt]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let resolvedUserPrompt = promptStack?.finalUserPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = resolvedUserPrompt?.nilIfEmpty
            ?? fallbackUserPrompt

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: systemPrompt.isEmpty ? fallbackSystemPrompt : systemPrompt,
                userPrompt: userPrompt,
                temperature: 0.2,
                maxOutputTokens: nil
            ),
            configuration: configuration,
            apiKey: apiKey
        )

        return V4ToolExecutionOutput(
            outputText: generation.outputText,
            evidenceSummary: "text.transform provider=\(generation.providerName) model=\(generation.modelName)",
            rawPayload: .object(
                [
                    "provider": .string(generation.providerName),
                    "model": .string(generation.modelName),
                    "outputText": .string(generation.outputText)
                ]
            )
        )
    }

    private func makeConfiguration(from endpoint: V4ModelEndpoint) throws -> TextGenerationProviderConfiguration {
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
