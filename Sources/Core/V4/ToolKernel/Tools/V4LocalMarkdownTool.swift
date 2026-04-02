import Foundation

final class V4LocalMarkdownTool: V4Tool, @unchecked Sendable {
    typealias BaseDirectoryResolver = @Sendable () -> URL
    typealias Clock = @Sendable () -> Date

    let spec = V4ToolSpec(
        toolName: "local.md.create",
        displayName: "本地 Markdown 归档",
        summary: "将处理结果写入本地 md 目录，并返回文件路径。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, isRequired: false, summary: "原始命令"),
                V4ToolInputField(name: "title", kind: .string, isRequired: false, summary: "文档标题"),
                V4ToolInputField(name: "body", kind: .string, isRequired: true, summary: "文档正文"),
                V4ToolInputField(name: "sourceText", kind: .string, isRequired: false, summary: "原始选中文本")
            ],
            allowsAdditionalFields: true
        ),
        requiresPermission: false,
        permissionScope: nil,
        isConcurrencySafe: true,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let errorCatalog = V4ToolErrorCatalog()
    private let baseDirectoryResolver: BaseDirectoryResolver
    private let clock: Clock
    private let fileManager: FileManager

    init(
        baseDirectoryResolver: BaseDirectoryResolver? = nil,
        clock: Clock? = nil,
        fileManager: FileManager = .default
    ) {
        self.baseDirectoryResolver = baseDirectoryResolver ?? {
            let sourceFileURL = URL(fileURLWithPath: #filePath)
            let repoRoot = sourceFileURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return repoRoot
        }
        self.clock = clock ?? { Date() }
        self.fileManager = fileManager
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let body = arguments.string(for: "body")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`body` 不能为空。",
                messageForDebug: "local md body empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let body = arguments.string(for: "body")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else {
            throw errorCatalog.semanticValidationFailure(
                toolID: spec.toolID,
                failure: V4ToolSemanticValidationFailure(
                    messageForUser: "`body` 不能为空。",
                    messageForDebug: "local md body empty"
                )
            )
        }

        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceText = arguments.string(for: "sourceText")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = resolvedTitle(from: arguments, body: body)
        let createdAt = clock()

        do {
            let folderURL = try ensureMarkdownDirectory()
            let fileURL = folderURL.appendingPathComponent(fileName(title: title, date: createdAt), isDirectory: false)
            let content = markdownDocument(
                title: title,
                command: command,
                sourceText: sourceText,
                body: body,
                date: createdAt
            )
            try content.write(to: fileURL, atomically: true, encoding: .utf8)

            let path = fileURL.path
            return V4ToolExecutionOutput(
                outputText: "已写入本地 md：\(path)",
                evidenceSummary: "local.md.create file=\(path)",
                rawPayload: .object(
                    [
                        "path": .string(path),
                        "title": .string(title),
                        "bytes": .number(Double(content.utf8.count))
                    ]
                )
            )
        } catch {
            throw errorCatalog.executionFailure(
                toolID: spec.toolID,
                userMessage: "本地 md 写入失败，请检查目录权限后重试。",
                debugMessage: error.localizedDescription,
                recoverAction: "check_local_directory_permission",
                isRetryable: false
            )
        }
    }

    private func ensureMarkdownDirectory() throws -> URL {
        let rootURL = baseDirectoryResolver()
        let mdURL = rootURL.appendingPathComponent("md", isDirectory: true)
        if !fileManager.fileExists(atPath: mdURL.path) {
            try fileManager.createDirectory(at: mdURL, withIntermediateDirectories: true)
        }
        return mdURL
    }

    private func resolvedTitle(from arguments: V4ToolArguments, body: String) -> String {
        if let explicit = arguments.string(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let firstLine = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !firstLine.isEmpty {
            return String(firstLine.prefix(40))
        }
        return "PulseType 本地记录"
    }

    private func fileName(title: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: date)
        let slug = slugified(title)
        return "\(timestamp)-\(slug).md"
    }

    private func slugified(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "note"
        }
        let replaced = trimmed.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: "-", options: .regularExpression)
        let compact = replaced.replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        let bounded = String(compact.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
        return bounded.isEmpty ? "note" : bounded
    }

    private func markdownDocument(
        title: String,
        command: String,
        sourceText: String,
        body: String,
        date: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateText = formatter.string(from: date)

        var lines: [String] = []
        lines.append("# \(title)")
        lines.append("")
        lines.append("- created_at: \(dateText)")
        if !command.isEmpty {
            lines.append("- command: \(command)")
        }
        lines.append("")
        if !sourceText.isEmpty {
            lines.append("## 原文")
            lines.append("")
            lines.append(sourceText)
            lines.append("")
        }
        lines.append("## 结果")
        lines.append("")
        lines.append(body)
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
