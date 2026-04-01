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
        requiresPermission: true,
        permissionScope: .textProcessing,
        isConcurrencySafe: true,
        mutatesUserData: false,
        supportsStreamingResults: false
    )

    private let providerSettingsStore: ProviderSettingsStore?
    private let generationProvider: any TextGenerationProvider
    private let executeHandler: (@Sendable (String, String) async throws -> V4ToolExecutionOutput)?

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        generationProvider: any TextGenerationProvider,
        executeHandler: (@Sendable (String, String) async throws -> V4ToolExecutionOutput)? = nil
    ) {
        self.providerSettingsStore = providerSettingsStore
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
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let text = arguments.string(for: "text") ?? ""
        let instruction = arguments.string(for: "instruction") ?? ""

        if let executeHandler {
            return try await executeHandler(text, instruction)
        }

        guard let providerSettingsStore else {
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
            let resolved = try await MainActor.run {
                let configuration = providerSettingsStore.rewriteConfiguration
                let apiKey = try providerSettingsStore.loadAPIKeyForRewriteProvider()?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (configuration, apiKey)
            }
            configuration = resolved.0
            apiKey = resolved.1
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

        guard !apiKey.isEmpty else {
            throw V4ToolError(
                code: .toolExecutionFailed,
                toolID: spec.toolID,
                messageForUser: "当前没有可用的文本模型 API key，请先在设置里配置。",
                messageForDebug: "rewrite provider api key missing",
                recoverAction: "open_provider_settings",
                isRetryable: false
            )
        }

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: """
                你是 PulseType 的文字处理工具。只输出处理后的文本，不要解释。
                """,
                userPrompt: """
                指令：
                \(instruction)

                原文：
                \(text)
                """,
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
}
