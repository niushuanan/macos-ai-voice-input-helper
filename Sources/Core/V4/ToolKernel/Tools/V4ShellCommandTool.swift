import Foundation

struct V4ShellCommandTool: V4Tool {
    static let defaultAllowlist: Set<String> = [
        "/bin/date",
        "/bin/echo",
        "/bin/ls",
        "/bin/pwd",
        "/usr/bin/id",
        "/usr/bin/osascript",
        "/usr/bin/uname",
        "/usr/bin/whoami",
        "date",
        "echo",
        "id",
        "ls",
        "osascript",
        "pwd",
        "uname",
        "whoami"
    ]

    let spec: V4ToolSpec
    private let allowlist: Set<String>
    private let errorCatalog = V4ToolErrorCatalog()

    init(allowlist: Set<String> = V4ShellCommandTool.defaultAllowlist) {
        self.allowlist = allowlist
        self.spec = V4ToolSpec(
            toolName: "shell.command.run",
            displayName: "执行命令",
            summary: "按 allowlist 运行可执行文件和参数。",
            supportedLanes: V4Lane.allCases,
            inputSchemaVersion: "v1",
            inputSchema: V4ToolInputSchema(
                fields: [
                    V4ToolInputField(name: "command", kind: .string, summary: "可执行文件"),
                    V4ToolInputField(name: "arguments", kind: .array, itemKind: .string, summary: "参数数组")
                ]
            ),
            requiresPermission: false,
            permissionScope: nil,
            isConcurrencySafe: false,
            mutatesUserData: true,
            supportsStreamingResults: false
        )
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let items = arguments.stringArray(for: "arguments") ?? []

        if command.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`command` 不能为空。",
                messageForDebug: "command empty"
            )
        }
        if !allowlist.contains(command) {
            return V4ToolSemanticValidationFailure(
                messageForUser: "命令 `\(command)` 不在 allowlist 内，当前不允许执行。",
                messageForDebug: "command not allowed: \(command)",
                recoverAction: "use_allowed_command"
            )
        }
        if items.contains(where: { $0.contains("\n") || $0.contains("\r") }) {
            return V4ToolSemanticValidationFailure(
                messageForUser: "参数里不能包含换行。",
                messageForDebug: "argument contains newline"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let command = arguments.string(for: "command") ?? ""
        let args = arguments.stringArray(for: "arguments") ?? []
        let resolvedCommand = resolvedExecutablePath(for: command)
        let process = await runProcess(executablePath: resolvedCommand, arguments: args)

        guard process.exitCode == 0 else {
            throw errorCatalog.executionFailure(
                toolID: spec.toolID,
                userMessage: "命令执行失败，请检查参数后再试。",
                debugMessage: process.detail,
                recoverAction: "retry_command",
                isRetryable: false
            )
        }

        let outputText = [
            "exit_code=\(process.exitCode)",
            process.stdout.isEmpty ? nil : "stdout:\n\(process.stdout)",
            process.stderr.isEmpty ? nil : "stderr:\n\(process.stderr)"
        ]
        .compactMap { $0 }
        .joined(separator: "\n")

        return V4ToolExecutionOutput(
            outputText: outputText,
            evidenceSummary: "shell.command.run exitCode=\(process.exitCode)",
            rawPayload: .object(
                [
                    "command": .string(resolvedCommand),
                    "arguments": .array(args.map(V4ToolValue.string)),
                    "exitCode": .number(Double(process.exitCode)),
                    "stdout": .string(process.stdout),
                    "stderr": .string(process.stderr)
                ]
            )
        )
    }

    private func resolvedExecutablePath(for command: String) -> String {
        switch command {
        case "date":
            return "/bin/date"
        case "echo":
            return "/bin/echo"
        case "ls":
            return "/bin/ls"
        case "pwd":
            return "/bin/pwd"
        case "id":
            return "/usr/bin/id"
        case "osascript":
            return "/usr/bin/osascript"
        case "uname":
            return "/usr/bin/uname"
        case "whoami":
            return "/usr/bin/whoami"
        default:
            return command
        }
    }
}
