import Foundation

struct V4AppleScriptTool: V4Tool {
    struct ResultPayload: Equatable, Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    typealias Runner = @Sendable (_ lines: [String], _ arguments: [String]) async -> ResultPayload

    let spec = V4ToolSpec(
        toolName: "applescript.run",
        displayName: "执行 AppleScript",
        summary: "执行受控 AppleScript 片段并返回结构化结果。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "scriptLines", kind: .array, itemKind: .string, summary: "AppleScript 行数组"),
                V4ToolInputField(name: "arguments", kind: .array, isRequired: false, itemKind: .string, summary: "argv 参数")
            ]
        ),
        requiresPermission: false,
        permissionScope: nil,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let runner: Runner
    private let errorCatalog = V4ToolErrorCatalog()

    init(
        runner: @escaping Runner = { lines, arguments in
            let result = await runOsaScript(lines: lines, arguments: arguments)
            return ResultPayload(stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode)
        }
    ) {
        self.runner = runner
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let scriptLines = arguments.stringArray(for: "scriptLines") ?? []
        guard scriptLines.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`scriptLines` 不能为空。",
                messageForDebug: "scriptLines empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let scriptLines = arguments.stringArray(for: "scriptLines") ?? []
        let scriptArguments = arguments.stringArray(for: "arguments") ?? []
        let result = await runner(scriptLines, scriptArguments)

        guard result.exitCode == 0 else {
            throw errorCatalog.executionFailure(
                toolID: spec.toolID,
                userMessage: "AppleScript 执行失败，请检查脚本内容后再试。",
                debugMessage: result.stderr.isEmpty ? result.stdout : result.stderr,
                recoverAction: "retry_command",
                isRetryable: true
            )
        }

        let outputText = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "AppleScript 已执行。"
            : result.stdout
        return V4ToolExecutionOutput(
            outputText: outputText,
            evidenceSummary: "applescript.run exitCode=0",
            rawPayload: .object(
                [
                    "stdout": .string(result.stdout),
                    "stderr": .string(result.stderr),
                    "exitCode": .number(Double(result.exitCode))
                ]
            )
        )
    }
}
