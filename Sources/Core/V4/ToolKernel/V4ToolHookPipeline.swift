import Foundation

struct V4ToolHookPipeline: V4ToolHookRunning {
    private let hooks: [any V4ToolLifecycleHook]

    init(hooks: [any V4ToolLifecycleHook] = []) {
        self.hooks = hooks
    }

    func runPreHooks(
        toolUse: V4ToolUse,
        input: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolPreHookResult {
        var currentInput = input
        var evidenceLines = [String]()

        for hook in hooks where hook.descriptor.phase == .preExecution {
            guard let result = try await hook.beforeExecution(
                toolUse: toolUse,
                input: currentInput,
                context: context
            ) else {
                continue
            }
            currentInput = result.input
            evidenceLines.append(contentsOf: result.evidenceLines)
        }

        return V4ToolPreHookResult(input: currentInput, evidenceLines: evidenceLines)
    }

    func runPostHooks(
        toolUse: V4ToolUse,
        output: V4ToolExecutionOutput,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolPostHookResult {
        var currentOutput = output
        var evidenceLines = [String]()

        for hook in hooks where hook.descriptor.phase == .postExecution {
            guard let result = try await hook.afterExecution(
                toolUse: toolUse,
                output: currentOutput,
                context: context
            ) else {
                continue
            }
            currentOutput = result.output
            evidenceLines.append(contentsOf: result.evidenceLines)
        }

        return V4ToolPostHookResult(output: currentOutput, evidenceLines: evidenceLines)
    }

    func runFailureHooks(
        toolUse: V4ToolUse,
        error: V4ToolError,
        context: V4ToolExecutionContext
    ) async {
        for hook in hooks where hook.descriptor.phase == .postFailure {
            await hook.afterFailure(toolUse: toolUse, error: error, context: context)
        }
    }

    func allHooks() -> [V4ToolHook] {
        hooks.map(\.descriptor)
    }
}
