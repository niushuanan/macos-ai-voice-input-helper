import Foundation

final class V4ToolKernel: V4ToolKernelRunning, @unchecked Sendable {
    private let registry: V4ToolRegistry
    private let permissionGate: any V4ToolPermissionChecking
    private let hookPipeline: any V4ToolHookRunning
    private let evidenceNormalizer: V4EvidenceNormalizer
    private let errorCatalog: V4ToolErrorCatalog
    private let evidencePolicy: V4ToolEvidencePolicy

    init(
        registry: V4ToolRegistry = .live(),
        permissionGate: any V4ToolPermissionChecking = V4PermissionGate(),
        hookPipeline: any V4ToolHookRunning = V4ToolHookPipeline(),
        evidenceNormalizer: V4EvidenceNormalizer = V4EvidenceNormalizer(),
        errorCatalog: V4ToolErrorCatalog = V4ToolErrorCatalog(),
        evidencePolicy: V4ToolEvidencePolicy = V4ToolEvidencePolicy()
    ) {
        self.registry = registry
        self.permissionGate = permissionGate
        self.hookPipeline = hookPipeline
        self.evidenceNormalizer = evidenceNormalizer
        self.errorCatalog = errorCatalog
        self.evidencePolicy = evidencePolicy
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
            let error = errorCatalog.missingTool(toolID: toolUse.toolID)
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
        let manifest = registry.manifest(for: tool.spec.toolID) ?? V4ToolManifest.derived(from: tool.spec)

        let parsedArguments: V4ToolArguments
        do {
            parsedArguments = try decodeArguments(from: toolUse.inputJSON)
        } catch {
            let normalizedError = errorCatalog.invalidJSON(toolID: toolUse.toolID, error: error)
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
            let normalizedError = errorCatalog.schemaValidationFailure(
                toolID: toolUse.toolID,
                issues: schemaIssues,
                payload: V4ToolValue.object(parsedArguments)
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
            let normalizedError = errorCatalog.semanticValidationFailure(
                toolID: toolUse.toolID,
                failure: semanticFailure
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
            let normalizedError = errorCatalog.permissionDenied(
                toolID: toolUse.toolID,
                decision: permissionDecision
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
            if let evidenceError = evidencePolicy.validate(
                output: postHookResult.output,
                manifest: manifest,
                toolID: toolUse.toolID,
                errorCatalog: errorCatalog
            ) {
                let normalizedError = errorCatalog.applyingRetryPolicy(
                    to: evidenceError,
                    manifest: manifest,
                    attemptCount: context.step.attemptCount
                )
                await hookPipeline.runFailureHooks(toolUse: toolUse, error: normalizedError, context: context)
                return evidenceNormalizer.normalize(
                    toolUse: toolUse,
                    status: .failed,
                    outputText: nil,
                    evidenceLines: [postHookResult.output.evidenceSummary],
                    rawPayload: postHookResult.output.rawPayload,
                    startedAt: startedAt,
                    finishedAt: Date(),
                    error: normalizedError
                )
            }

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
            let normalizedError = normalize(
                error: error,
                toolID: toolUse.toolID,
                manifest: manifest,
                attemptCount: context.step.attemptCount
            )
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
        case "apple.calendar.create":
            return [
                "command": .string(step.inputSummary.nilIfEmpty ?? request.inputText),
                "title": .string(defaultNoteTitle(from: preferredText))
            ]
        case "apple.mail.compose":
            let command = step.inputSummary.nilIfEmpty ?? request.inputText
            var arguments: V4ToolArguments = [
                "command": .string(command),
                "deliveryMode": .string(inferredMailDeliveryMode(from: command).rawValue)
            ]
            if let mailBody = latestOutput?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? selectionText?.nilIfEmpty
            {
                arguments["body"] = .string(mailBody)
            }
            return arguments
        case "apple.music.control":
            return [
                "command": .string(step.inputSummary.nilIfEmpty ?? request.inputText),
            ]
        case "feishu.cli":
            return [
                "command": .string(step.inputSummary.nilIfEmpty ?? request.inputText),
                "arguments": .array([])
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

    private func inferredMailDeliveryMode(from command: String) -> MagicianMailDeliveryMode {
        let lowered = command.lowercased()
        if containsAny(lowered, tokens: ["草稿", "draft"]) {
            return .draftOnly
        }
        if containsAny(lowered, tokens: ["发送", "发出", "send", "发给", "发邮件", "邮件发给"]) {
            return .autoSendIfResolved
        }
        return .draftOnly
    }

    private func containsAny(_ value: String, tokens: [String]) -> Bool {
        tokens.contains { value.contains($0) }
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

    private func normalize(
        error: Error,
        toolID: String,
        manifest: V4ToolManifest,
        attemptCount: Int
    ) -> V4ToolError {
        let normalized = errorCatalog.normalize(error: error, toolID: toolID)
        return errorCatalog.applyingRetryPolicy(
            to: normalized,
            manifest: manifest,
            attemptCount: attemptCount
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
