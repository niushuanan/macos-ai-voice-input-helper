import Foundation

struct V4TimeMachineCreateTool: V4Tool {
    let spec = V4ToolSpec(
        toolName: "time_machine.create",
        displayName: "记录到时光机",
        summary: "把一句灵感或待办保存到本地时光机。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "原始语音命令")
            ]
        ),
        requiresPermission: false,
        permissionScope: nil,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let service: V4TimeMachineService

    init(service: V4TimeMachineService) {
        self.service = service
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`command` 不能为空。",
                messageForDebug: "command empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let command = arguments.string(for: "command") ?? ""
        let result = try await service.create(
            rawCommand: command,
            context: V4TimeMachineRequestContext(request: context.request)
        )

        let outputText = "已记到时光机：\(result.item.normalizedText)"
        return V4ToolExecutionOutput(
            outputText: outputText,
            evidenceSummary: "time_machine.create item_id=\(result.item.id) parse=none schedule=not_requested",
            rawPayload: .object(
                [
                    "itemID": .string(result.item.id),
                    "normalizedText": .string(result.item.normalizedText),
                    "status": .string(result.item.status.rawValue),
                    "tags": .array(result.item.tags.map(V4ToolValue.string))
                ]
            )
        )
    }
}
