import Foundation

struct V4FeishuCLITool: V4Tool {
    struct Response: Equatable, Sendable {
        let outputText: String?
        let userMessage: String
        let evidenceSummary: String?
        let verificationStatus: MagicianAgentVerificationStatus
        let operation: String
    }

    typealias ExecuteHandler = @Sendable (_ command: String, _ operation: String?, _ arguments: [String]) async throws -> Response

    let spec = V4ToolSpec(
        toolName: "feishu.cli",
        displayName: "执行飞书命令",
        summary: "执行飞书 CLI，并要求返回结构化证据。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "原始命令"),
                V4ToolInputField(name: "operation", kind: .string, isRequired: false, summary: "canonical operation"),
                V4ToolInputField(name: "arguments", kind: .array, isRequired: false, itemKind: .string, summary: "CLI 参数")
            ]
        ),
        requiresPermission: true,
        permissionScope: .feishu,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let executeHandler: ExecuteHandler
    private let errorCatalog = V4ToolErrorCatalog()

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        cliRegistry: MagicianCLIRegistry = MagicianCLIRegistry(),
        executeHandler: ExecuteHandler? = nil
    ) {
        if let executeHandler {
            self.executeHandler = executeHandler
        } else {
            self.executeHandler = Self.liveExecuteHandler(
                providerSettingsStore: providerSettingsStore,
                cliRegistry: cliRegistry
            )
        }
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`command` 不能为空。",
                messageForDebug: "feishu command empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let command = arguments.string(for: "command") ?? ""
        let response = try await executeHandler(
            command,
            arguments.string(for: "operation"),
            arguments.stringArray(for: "arguments") ?? []
        )
        var rawObject: [String: V4ToolValue] = [
            "operation": .string(response.operation),
            "userMessage": .string(response.userMessage),
            "verificationStatus": .string(response.verificationStatus.rawValue)
        ]
        let evidenceFields = parsedEvidenceFields(from: response.evidenceSummary)
        for (key, value) in evidenceFields {
            rawObject[key] = .string(value)
        }
        if let evidenceID = evidenceFields["event_id"]
            ?? evidenceFields["message_id"]
            ?? evidenceFields["doc_id"]
            ?? evidenceFields["file_token"]
            ?? evidenceFields["task_id"]
            ?? evidenceFields["base_id"]
        {
            rawObject["evidenceID"] = .string(evidenceID)
        }
        return V4ToolExecutionOutput(
            outputText: response.outputText ?? response.userMessage,
            evidenceSummary: response.evidenceSummary ?? "",
            rawPayload: .object(rawObject)
        )
    }

    private func parsedEvidenceFields(from evidenceSummary: String?) -> [String: String] {
        guard let evidenceSummary else {
            return [:]
        }
        return evidenceSummary
            .split(separator: ";")
            .reduce(into: [String: String]()) { partialResult, item in
                let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else {
                    return
                }
                partialResult[
                    String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                ] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    private static func liveExecuteHandler(
        providerSettingsStore: ProviderSettingsStore?,
        cliRegistry: MagicianCLIRegistry
    ) -> ExecuteHandler {
        { command, operationRaw, arguments in
            let operation = operationRaw.flatMap(FeishuCanonicalOperation.init(rawValue:))
                ?? FeishuCanonicalOperation.infer(from: command)
            guard let operation else {
                throw V4ToolErrorCatalog().semanticValidationFailure(
                    toolID: "feishu.cli",
                    failure: V4ToolSemanticValidationFailure(
                        messageForUser: "没识别到可执行的飞书动作，请补一句更具体的命令。",
                        messageForDebug: "feishu cli operation unresolved",
                        recoverAction: "retry_command"
                    )
                )
            }

            let executableOverride = await MainActor.run {
                providerSettingsStore?.resolvedFeishuCLIExecutablePathOverride
            }
            let availability = cliRegistry.currentFeishuAvailability(
                executableOverride: executableOverride
            )
            let result = await cliRegistry.executeFeishu(
                operation: operation,
                spokenCommand: command,
                explicitArguments: arguments,
                availability: availability
            )

            switch result {
            case let .success(success):
                return Response(
                    outputText: success.outputText,
                    userMessage: success.userMessage,
                    evidenceSummary: success.observation?.evidenceSummary,
                    verificationStatus: success.observation?.verificationStatus ?? .assumed,
                    operation: operation.rawValue
                )
            case let .failure(error):
                throw error
            }
        }
    }
}
