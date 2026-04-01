import Foundation

struct V4ToolErrorCatalog: Sendable {
    func missingTool(toolID: String) -> V4ToolError {
        V4ToolError(
            code: .invalidRequest,
            toolID: toolID,
            messageForUser: "当前还没有名为 `\(toolID)` 的工具。",
            messageForDebug: "tool spec missing in registry",
            recoverAction: "check_tool_registry",
            isRetryable: false
        )
    }

    func invalidJSON(
        toolID: String,
        error: Error
    ) -> V4ToolError {
        V4ToolError(
            code: .toolValidationFailed,
            toolID: toolID,
            messageForUser: "工具输入不是合法 JSON。",
            messageForDebug: String(describing: error),
            recoverAction: "fix_tool_input",
            isRetryable: false
        )
    }

    func schemaValidationFailure(
        toolID: String,
        issues: [String],
        payload: V4ToolValue? = nil
    ) -> V4ToolError {
        let _ = payload
        return V4ToolError(
            code: .toolValidationFailed,
            toolID: toolID,
            messageForUser: issues.joined(separator: " "),
            messageForDebug: "schema validation failed: \(issues.joined(separator: " | "))",
            recoverAction: "fix_tool_input",
            isRetryable: false
        )
    }

    func semanticValidationFailure(
        toolID: String,
        failure: V4ToolSemanticValidationFailure
    ) -> V4ToolError {
        V4ToolError(
            code: failure.code,
            toolID: toolID,
            messageForUser: failure.messageForUser,
            messageForDebug: failure.messageForDebug,
            recoverAction: failure.recoverAction,
            isRetryable: false
        )
    }

    func permissionDenied(
        toolID: String,
        decision: V4PermissionDecision
    ) -> V4ToolError {
        V4ToolError(
            code: .permissionDenied,
            toolID: toolID,
            messageForUser: decision.userMessage ?? "当前没有权限执行该工具。",
            messageForDebug: decision.reason,
            recoverAction: "enable_feature_scope",
            isRetryable: false
        )
    }

    func missingEvidence(
        toolID: String,
        requirement: V4ToolEvidenceRequirement,
        debugMessage: String
    ) -> V4ToolError {
        let userMessage: String
        switch requirement.level {
        case .none:
            userMessage = "执行结果缺少核验证据，已判定失败。"
        case .summary:
            userMessage = "执行结果缺少核验证据，已判定失败。"
        case .structured:
            userMessage = "执行结果缺少结构化证据，已判定失败。"
        }

        return V4ToolError(
            code: .verificationFailed,
            toolID: toolID,
            messageForUser: userMessage,
            messageForDebug: debugMessage,
            recoverAction: "retry_command",
            isRetryable: false
        )
    }

    func executionFailure(
        toolID: String,
        userMessage: String,
        debugMessage: String,
        recoverAction: String? = "retry_command",
        isRetryable: Bool = true
    ) -> V4ToolError {
        V4ToolError(
            code: .toolExecutionFailed,
            toolID: toolID,
            messageForUser: userMessage,
            messageForDebug: debugMessage,
            recoverAction: recoverAction,
            isRetryable: isRetryable
        )
    }

    func bridgeNotReady(
        toolID: String,
        userMessage: String,
        debugMessage: String,
        recoverAction: String? = "retry_command"
    ) -> V4ToolError {
        V4ToolError(
            code: .bridgeNotReady,
            toolID: toolID,
            messageForUser: userMessage,
            messageForDebug: debugMessage,
            recoverAction: recoverAction,
            isRetryable: true
        )
    }

    func normalize(
        error: Error,
        toolID: String
    ) -> V4ToolError {
        if let toolError = error as? V4ToolError {
            return toolError
        }

        if let magicianError = error as? MagicianError {
            switch magicianError.code {
            case .permissionDenied, .mailAutomationDenied:
                return V4ToolError(
                    code: .permissionDenied,
                    toolID: toolID,
                    messageForUser: magicianError.userMessage,
                    messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                    recoverAction: magicianError.recoverAction,
                    isRetryable: false
                )
            case .intentParseFailed, .mailRecipientUnresolved, .cliCommandRejected:
                return V4ToolError(
                    code: .toolValidationFailed,
                    toolID: toolID,
                    messageForUser: magicianError.userMessage,
                    messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                    recoverAction: magicianError.recoverAction,
                    isRetryable: false
                )
            case .cliUnavailable, .mailUnavailable, .musicUnavailable, .browserUnavailable:
                return V4ToolError(
                    code: .bridgeNotReady,
                    toolID: toolID,
                    messageForUser: magicianError.userMessage,
                    messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                    recoverAction: magicianError.recoverAction,
                    isRetryable: true
                )
            case .cliAuthRequired:
                return V4ToolError(
                    code: .bridgeNotReady,
                    toolID: toolID,
                    messageForUser: magicianError.userMessage,
                    messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                    recoverAction: magicianError.recoverAction,
                    isRetryable: false
                )
            case .selectionEmpty:
                return V4ToolError(
                    code: .toolValidationFailed,
                    toolID: toolID,
                    messageForUser: magicianError.userMessage,
                    messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                    recoverAction: magicianError.recoverAction,
                    isRetryable: false
                )
            case .eventCreateFailed,
                 .shortcutNotFound,
                 .mailAppleScriptFailed,
                 .toolExecutionFailed,
                 .musicControlFailed,
                 .cliExecutionTimedOut:
                return V4ToolError(
                    code: .toolExecutionFailed,
                    toolID: toolID,
                    messageForUser: magicianError.userMessage,
                    messageForDebug: magicianError.debugMessage ?? magicianError.code.rawValue,
                    recoverAction: magicianError.recoverAction,
                    isRetryable: magicianError.code != .shortcutNotFound
                )
            }
        }

        return V4ToolError(
            code: .toolExecutionFailed,
            toolID: toolID,
            messageForUser: "工具执行失败，请稍后再试。",
            messageForDebug: String(describing: error),
            recoverAction: "retry_command",
            isRetryable: true
        )
    }

    func applyingRetryPolicy(
        to error: V4ToolError,
        manifest: V4ToolManifest,
        attemptCount: Int
    ) -> V4ToolError {
        V4ToolError(
            code: error.code,
            toolID: error.toolID,
            messageForUser: error.messageForUser,
            messageForDebug: error.messageForDebug,
            recoverAction: error.recoverAction,
            isRetryable: manifest.retryPolicy.allowsRetry(error: error, attemptCount: attemptCount)
        )
    }
}
