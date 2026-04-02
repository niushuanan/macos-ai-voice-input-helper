import Foundation

@MainActor
protocol MagicianToolExecuting {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult
}

@MainActor
// legacy executor: 只保留旧 runtime -> V4 ToolKernel 的桥接入口。
final class MagicianToolExecutor: MagicianToolExecuting {
    private let providerSettingsStore: ProviderSettingsStore?
    private let mailAddressBookStore: MailAddressBookStore?
    private let generationProvider: any TextGenerationProvider
    private let cliRegistry: MagicianCLIRegistry

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        mailAddressBookStore: MailAddressBookStore? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        cliRegistry: MagicianCLIRegistry = MagicianCLIRegistry()
    ) {
        self.providerSettingsStore = providerSettingsStore
        self.mailAddressBookStore = mailAddressBookStore
        self.generationProvider = generationProvider
        self.cliRegistry = cliRegistry
    }

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        guard intent.intent != .textTransform else {
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "文字处理应该走改写链路，当前执行器不处理这个动作。",
                debugMessage: "textTransform routed to MagicianToolExecutor",
                recoverAction: "check_router_logic"
            )
        }

        let toolName = v4ToolName(for: intent.intent)
        let arguments = bridgeArguments(intent: intent, context: context)
        let request = V4RunRequest(
            traceID: V4TraceID(rawValue: UUID().uuidString),
            lane: .selectionRewrite,
            goalSummary: context.command.trimmingCharacters(in: .whitespacesAndNewlines),
            inputText: context.command,
            appName: context.focusContext.appName,
            bundleID: context.focusContext.bundleID,
            selectionText: context.selectedText.isEmpty ? nil : context.selectedText,
            enabledFeatureIDs: [intent.intent.rawValue]
        )
        let step = V4StepRecord(
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            title: toolName,
            status: .queued,
            toolName: toolName,
            inputSummary: context.command
        )
        let toolUse = V4ToolUse(
            runID: request.runID,
            stepID: step.id,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            toolName: toolName,
            inputJSON: encodeArguments(arguments),
            inputSummary: context.command,
            requestedAt: Date()
        )
        let toolContext = V4ToolExecutionContext(
            toolUse: toolUse,
            request: request,
            step: step,
            accumulatedStepRecords: [],
            turnIndex: 1
        )

        let kernel = V4ToolKernel(
            registry: V4ToolRegistry.live(
                generationProvider: generationProvider,
                providerSettingsStore: providerSettingsStore,
                mailAddressBookStore: mailAddressBookStore,
                cliRegistry: cliRegistry
            ),
            permissionGate: V4PermissionGate()
        )
        let result = await kernel.execute(toolUse: toolUse, context: toolContext)

        if let error = result.error {
            throw magicianError(from: error)
        }
        return bridgeResult(
            from: result,
            intent: intent.intent,
            arguments: arguments
        )
    }

    private func v4ToolName(for featureID: MagicianFeatureID) -> String {
        switch featureID {
        case .createEvent:
            return "apple.calendar.create"
        case .createNote:
            return "apple.notes.create"
        case .composeEmailDraft:
            return "apple.mail.compose"
        case .controlMusic:
            return "apple.music.control"
        case .feishuCLI:
            return "feishu.cli"
        case .textTransform:
            return "text.transform"
        }
    }

    private func bridgeArguments(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> V4ToolArguments {
        switch intent.intent {
        case .createEvent:
            var arguments: V4ToolArguments = [
                "command": .string(context.command)
            ]
            appendIfExists(intent.params.title, key: "title", into: &arguments)
            appendIfExists(intent.params.startAt, key: "startAt", into: &arguments)
            appendIfExists(intent.params.endAt, key: "endAt", into: &arguments)
            appendIfExists(intent.params.location, key: "location", into: &arguments)
            appendIfExists(intent.params.notes, key: "notes", into: &arguments)
            return arguments

        case .createNote:
            let body = resolvedNoteBody(intent: intent, context: context)
            return [
                "command": .string(context.command),
                "action": .string("create"),
                "title": .string(String(body.prefix(40)).ifEmpty("PulseType 速记")),
                "body": .string(body)
            ]

        case .composeEmailDraft:
            var arguments: V4ToolArguments = [
                "command": .string(context.command),
                "deliveryMode": .string((intent.params.mailDeliveryMode ?? .draftOnly).rawValue)
            ]
            appendIfExists(intent.params.mailSubject, key: "subject", into: &arguments)
            appendIfExists(intent.params.mailBody ?? context.selectedText.nilIfEmpty, key: "body", into: &arguments)
            if let recipients = intent.params.mailTo, !recipients.isEmpty {
                arguments["recipients"] = .array(recipients.map(V4ToolValue.string))
            }
            if let recipientHints = intent.params.mailRecipientHints, !recipientHints.isEmpty {
                arguments["recipientHints"] = .array(recipientHints.map(V4ToolValue.string))
            }
            return arguments

        case .controlMusic:
            var arguments: V4ToolArguments = [
                "command": .string(context.command)
            ]
            if let query = intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                arguments["query"] = .string(query)
            }
            return arguments

        case .feishuCLI:
            var arguments: V4ToolArguments = [
                "command": .string(context.command)
            ]
            appendIfExists(intent.params.cliOperation, key: "operation", into: &arguments)
            if let cliArguments = intent.params.cliArguments, !cliArguments.isEmpty {
                arguments["arguments"] = .array(cliArguments.map(V4ToolValue.string))
            }
            return arguments

        case .textTransform:
            return [:]
        }
    }

    private func resolvedNoteBody(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        intent.params.noteBody?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.selectedText.nilIfEmpty
            ?? intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? context.command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bridgeResult(
        from result: V4ToolResult,
        intent: MagicianFeatureID,
        arguments: V4ToolArguments
    ) -> MagicianExecutionResult {
        let payload = decodePayload(from: result.rawPayload)
        let evidenceSummary = result.evidenceSummary.nilIfEmpty
        let verificationStatus = payload.string(for: "verificationStatus")
            .flatMap(MagicianAgentVerificationStatus.init(rawValue:))
            ?? .verified
        let userMessage = payload.string(for: "userMessage")?.nilIfEmpty
            ?? defaultUserMessage(intent: intent, payload: payload, fallback: result.outputText)
        let historyDisplayText = payload.string(for: "historyDisplayText")?.nilIfEmpty
            ?? defaultHistoryText(intent: intent, payload: payload, arguments: arguments, outputText: result.outputText)

        return MagicianExecutionResult(
            intent: intent,
            userMessage: userMessage,
            outputText: result.outputText,
            historyDisplayText: historyDisplayText,
            fallbackUsed: payload.bool(for: "autoRepairApplied") ?? payload.bool(for: "usedFallback") ?? false,
            observation: MagicianAgentObservation(
                verificationStatus: verificationStatus,
                targetSummary: payload.string(for: "title")
                    ?? payload.string(for: "targetSummary")
                    ?? payload.string(for: "eventID")
                    ?? payload.string(for: "noteID")
                    ?? payload.string(for: "evidenceID"),
                evidenceSummary: evidenceSummary,
                autoRepairApplied: payload.bool(for: "autoRepairApplied") ?? payload.bool(for: "usedFallback") ?? false
            )
        )
    }

    private func defaultUserMessage(
        intent: MagicianFeatureID,
        payload: V4ToolArguments,
        fallback: String?
    ) -> String {
        switch intent {
        case .createEvent:
            return fallback ?? "已建日程"
        case .createNote:
            return "已写入 Notes。"
        case .composeEmailDraft:
            return fallback ?? "邮件已处理"
        case .controlMusic:
            return payload.string(for: "summary") ?? fallback ?? "已控制音乐"
        case .feishuCLI:
            return fallback ?? "飞书命令已执行"
        case .textTransform:
            return fallback ?? "已完成"
        }
    }

    private func defaultHistoryText(
        intent: MagicianFeatureID,
        payload: V4ToolArguments,
        arguments: V4ToolArguments,
        outputText: String?
    ) -> String? {
        switch intent {
        case .createEvent:
            return outputText
        case .createNote:
            let body = arguments.string(for: "body") ?? outputText ?? "无内容"
            return "已写入备忘录：\(summarizedHistoryText(body))"
        case .composeEmailDraft:
            return outputText ?? payload.string(for: "historyDisplayText")
        case .controlMusic:
            return payload.string(for: "summary") ?? outputText
        case .feishuCLI:
            return outputText.map { "飞书 CLI：\(summarizedHistoryText($0, limit: 96))" }
        case .textTransform:
            return outputText
        }
    }

    private func magicianError(from error: V4ToolError) -> MagicianError {
        let code: MagicianErrorCode
        switch error.code {
        case .permissionDenied:
            code = .permissionDenied
        case .toolValidationFailed, .invalidRequest:
            code = .intentParseFailed
        case .bridgeNotReady:
            code = bridgeNotReadyErrorCode(for: error.toolID)
        default:
            code = .toolExecutionFailed
        }
        return MagicianError(
            code: code,
            userMessage: error.messageForUser,
            debugMessage: error.messageForDebug,
            recoverAction: error.recoverAction
        )
    }

    private func bridgeNotReadyErrorCode(for toolID: String) -> MagicianErrorCode {
        switch toolID {
        case "feishu.cli":
            return .cliUnavailable
        case "apple.mail.compose":
            return .mailUnavailable
        case "apple.music.control":
            return .musicUnavailable
        default:
            return .toolExecutionFailed
        }
    }

    private func encodeArguments(_ arguments: V4ToolArguments) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(V4ToolValue.object(arguments)),
              let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func decodePayload(from rawPayload: String?) -> V4ToolArguments {
        guard
            let rawPayload,
            let data = rawPayload.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(V4ToolValue.self, from: data),
            case let .object(object) = decoded
        else {
            return [:]
        }
        return object
    }

    private func appendIfExists(
        _ value: String?,
        key: String,
        into arguments: inout V4ToolArguments
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return
        }
        arguments[key] = .string(value)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
