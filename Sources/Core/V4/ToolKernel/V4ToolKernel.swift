import Foundation

final class V4ToolKernel: V4ToolKernelRunning, @unchecked Sendable {
    private let registry: V4ToolRegistry
    private let permissionGate: any V4ToolPermissionChecking
    private let hookPipeline: any V4ToolHookRunning
    private let evidenceNormalizer: V4EvidenceNormalizer

    init(
        registry: V4ToolRegistry = .live(),
        permissionGate: any V4ToolPermissionChecking = V4PermissionGate(),
        hookPipeline: any V4ToolHookRunning = V4ToolHookPipeline(),
        evidenceNormalizer: V4EvidenceNormalizer = V4EvidenceNormalizer()
    ) {
        self.registry = registry
        self.permissionGate = permissionGate
        self.hookPipeline = hookPipeline
        self.evidenceNormalizer = evidenceNormalizer
    }

    func execute(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords: [V4StepRecord],
        turnIndex: Int
    ) async -> V4ToolResult {
        let toolUse = makeToolUse(
            step: step,
            request: request,
            accumulatedStepRecords: accumulatedStepRecords
        )
        let context = V4ToolExecutionContext(
            toolUse: toolUse,
            request: request,
            step: step,
            accumulatedStepRecords: accumulatedStepRecords,
            turnIndex: turnIndex
        )
        return await execute(toolUse: toolUse, context: context)
    }

    func execute(
        toolUse: V4ToolUse,
        context: V4ToolExecutionContext
    ) async -> V4ToolResult {
        let startedAt = Date()

        guard let tool = registry.tool(for: toolUse.toolName) else {
            let error = V4ToolError(
                code: .invalidRequest,
                toolID: toolUse.toolID,
                messageForUser: "当前还没有名为 `\(toolUse.toolID)` 的工具。",
                messageForDebug: "tool spec missing in registry",
                recoverAction: "check_tool_registry",
                isRetryable: false
            )
            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: .failed,
                outputText: nil,
                evidenceLines: [],
                rawPayload: nil,
                startedAt: startedAt,
                finishedAt: Date(),
                error: error
            )
        }

        let parsedArguments: V4ToolArguments
        do {
            parsedArguments = try decodeArguments(from: toolUse.inputJSON)
        } catch {
            let normalizedError = V4ToolError(
                code: .toolValidationFailed,
                toolID: toolUse.toolID,
                messageForUser: "工具输入不是合法 JSON。",
                messageForDebug: String(describing: error),
                recoverAction: "fix_tool_input",
                isRetryable: false
            )
            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: .failed,
                outputText: nil,
                evidenceLines: [],
                rawPayload: nil,
                startedAt: startedAt,
                finishedAt: Date(),
                error: normalizedError
            )
        }

        let schemaIssues = tool.spec.inputSchema.validate(arguments: parsedArguments)
        if !schemaIssues.isEmpty {
            let normalizedError = V4ToolError(
                code: .toolValidationFailed,
                toolID: toolUse.toolID,
                messageForUser: schemaIssues.joined(separator: " "),
                messageForDebug: "schema validation failed: \(schemaIssues.joined(separator: " | "))",
                recoverAction: "fix_tool_input",
                isRetryable: false
            )
            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: .failed,
                outputText: nil,
                evidenceLines: [],
                rawPayload: V4ToolValue.object(parsedArguments),
                startedAt: startedAt,
                finishedAt: Date(),
                error: normalizedError
            )
        }

        if let semanticFailure = await tool.validateSemanticInput(arguments: parsedArguments, context: context) {
            let normalizedError = V4ToolError(
                code: semanticFailure.code,
                toolID: toolUse.toolID,
                messageForUser: semanticFailure.messageForUser,
                messageForDebug: semanticFailure.messageForDebug,
                recoverAction: semanticFailure.recoverAction,
                isRetryable: false
            )
            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: .failed,
                outputText: nil,
                evidenceLines: [],
                rawPayload: V4ToolValue.object(parsedArguments),
                startedAt: startedAt,
                finishedAt: Date(),
                error: normalizedError
            )
        }

        let permissionDecision = await permissionGate.evaluate(spec: tool.spec, request: context.request)
        if permissionDecision.behavior != .allow {
            let normalizedError = V4ToolError(
                code: .permissionDenied,
                toolID: toolUse.toolID,
                messageForUser: permissionDecision.userMessage ?? "当前没有权限执行该工具。",
                messageForDebug: permissionDecision.reason,
                recoverAction: "enable_feature_scope",
                isRetryable: false
            )
            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: .denied,
                outputText: nil,
                evidenceLines: [permissionDecision.reason],
                rawPayload: V4ToolValue.object(parsedArguments),
                startedAt: startedAt,
                finishedAt: Date(),
                error: normalizedError
            )
        }

        do {
            let preHookResult = try await hookPipeline.runPreHooks(
                toolUse: toolUse,
                input: parsedArguments,
                context: context
            )

            let executionOutput = try await tool.execute(
                arguments: preHookResult.input,
                context: context
            )

            let postHookResult = try await hookPipeline.runPostHooks(
                toolUse: toolUse,
                output: executionOutput,
                context: context
            )

            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: .success,
                outputText: postHookResult.output.outputText,
                evidenceLines: preHookResult.evidenceLines + [postHookResult.output.evidenceSummary] + postHookResult.evidenceLines,
                rawPayload: postHookResult.output.rawPayload,
                startedAt: startedAt,
                finishedAt: Date(),
                error: nil
            )
        } catch {
            let normalizedError = normalize(error: error, toolID: toolUse.toolID)
            await hookPipeline.runFailureHooks(toolUse: toolUse, error: normalizedError, context: context)
            return evidenceNormalizer.normalize(
                toolUse: toolUse,
                status: normalizedError.code == .permissionDenied ? .denied : .failed,
                outputText: nil,
                evidenceLines: [],
                rawPayload: V4ToolValue.object(parsedArguments),
                startedAt: startedAt,
                finishedAt: Date(),
                error: normalizedError
            )
        }
    }

    private func makeToolUse(
        step: V4StepRecord,
        request: V4RunRequest,
        accumulatedStepRecords: [V4StepRecord]
    ) -> V4ToolUse {
        let inputArguments = defaultInputArguments(
            for: step.toolName ?? "text.transform",
            request: request,
            step: step,
            accumulatedStepRecords: accumulatedStepRecords
        )

        return V4ToolUse(
            runID: request.runID,
            stepID: step.id,
            traceID: request.traceID,
            lane: request.lane,
            goalSummary: request.goalSummary,
            toolName: step.toolName ?? "text.transform",
            inputJSON: encodeArguments(inputArguments),
            inputSummary: step.inputSummary,
            requestedAt: Date()
        )
    }

    private func defaultInputArguments(
        for toolName: String,
        request: V4RunRequest,
        step: V4StepRecord,
        accumulatedStepRecords: [V4StepRecord]
    ) -> V4ToolArguments {
        let latestOutput = accumulatedStepRecords.reversed().compactMap(\.outputSummary).first
        let selectionText = request.selectionText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredText = latestOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? selectionText?.nilIfEmpty
            ?? step.inputSummary.nilIfEmpty
            ?? request.inputText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? ""

        switch toolName {
        case "text.transform":
            return [
                "text": .string(preferredText),
                "instruction": .string(step.inputSummary.nilIfEmpty ?? request.goalSummary)
            ]
        case "apple.notes.create":
            return [
                "title": .string(defaultNoteTitle(from: preferredText)),
                "body": .string(preferredText)
            ]
        case "shell.command.run":
            return [
                "command": .string("/bin/echo"),
                "arguments": .array([.string(preferredText)])
            ]
        case "time_machine.create", "time_machine.remind":
            return [
                "command": .string(
                    step.inputSummary.nilIfEmpty
                        ?? request.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ]
        default:
            return [:]
        }
    }

    private func defaultNoteTitle(from body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "PulseType 速记"
        }
        return String(trimmed.prefix(40))
    }

    private func decodeArguments(from inputJSON: String) throws -> V4ToolArguments {
        let data = Data(inputJSON.utf8)
        let decoded = try JSONDecoder().decode(V4ToolValue.self, from: data)
        guard case let .object(arguments) = decoded else {
            throw V4ToolError(
                code: .toolValidationFailed,
                toolID: "unknown",
                messageForUser: "工具输入必须是 JSON 对象。",
                messageForDebug: "top-level JSON is not object",
                recoverAction: "fix_tool_input",
                isRetryable: false
            )
        }
        return arguments
    }

    private func encodeArguments(_ arguments: V4ToolArguments) -> String {
        let payload = V4ToolValue.object(arguments)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(payload),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    private func normalize(error: Error, toolID: String) -> V4ToolError {
        if let toolError = error as? V4ToolError {
            return toolError
        }

        if let magicianError = error as? MagicianError {
            let failureCode: V4FailureCode
            switch magicianError.code {
            case .permissionDenied:
                failureCode = .permissionDenied
            case .intentParseFailed:
                failureCode = .toolValidationFailed
            default:
                failureCode = .toolExecutionFailed
            }
            return V4ToolError(
                code: failureCode,
                toolID: toolID,
                messageForUser: magicianError.userMessage,
                messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                recoverAction: magicianError.recoverAction,
                isRetryable: false
            )
        }

        return V4ToolError(
            code: .toolExecutionFailed,
            toolID: toolID,
            messageForUser: "工具执行失败，请稍后再试。",
            messageForDebug: String(describing: error),
            recoverAction: "retry_command",
            isRetryable: false
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
