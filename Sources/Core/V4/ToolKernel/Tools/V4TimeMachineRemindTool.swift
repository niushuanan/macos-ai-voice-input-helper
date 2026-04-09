import Foundation

struct V4TimeMachineRemindTool: V4Tool {
    let spec = V4ToolSpec(
        toolName: "time_machine.remind",
        displayName: "记录并提醒",
        summary: "把一句提醒保存到时光机，并创建本地通知。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "原始语音命令")
            ]
        ),
        requiresPermission: true,
        requiredFeature: .clock,
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
        let result = try await service.remind(
            rawCommand: command,
            context: V4TimeMachineRequestContext(request: context.request)
        )

        let parseSummary = result.parseResult?.resolutionSummary ?? "unknown"
        let scheduleSummary: String
        let outputText: String
        if let scheduleResult = result.scheduleResult, scheduleResult.status == .scheduled {
            scheduleSummary = "success"
            outputText = "已记到时光机，并会提醒你：\(result.item.normalizedText)"
        } else {
            scheduleSummary = "failed"
            outputText = "已记到时光机，但本地提醒没建成：\(result.scheduleResult?.userMessage ?? "未知错误")"
        }

        var payload: [String: V4ToolValue] = [
            "itemID": .string(result.item.id),
            "normalizedText": .string(result.item.normalizedText),
            "status": .string(result.item.status.rawValue),
            "parseSummary": .string(parseSummary),
            "tags": .array(result.item.tags.map(V4ToolValue.string))
        ]
        if let scheduledAt = result.item.scheduledAt {
            payload["scheduledAt"] = .string(iso8601String(from: scheduledAt))
        }
        if let notificationID = result.item.notificationID {
            payload["notificationID"] = .string(notificationID)
        }

        return V4ToolExecutionOutput(
            outputText: outputText,
            evidenceSummary: "time_machine.remind item_id=\(result.item.id) parse=\(parseSummary) schedule=\(scheduleSummary) notification_id=\(result.item.notificationID ?? "none")",
            rawPayload: .object(payload)
        )
    }

    private func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}
