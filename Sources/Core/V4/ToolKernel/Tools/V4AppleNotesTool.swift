import Foundation

struct V4AppleNotesTool: V4Tool {
    let spec = V4ToolSpec(
        toolName: "apple.notes.create",
        displayName: "写入备忘录",
        summary: "在 Apple Notes 创建新笔记，并返回可核验的证据。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "title", kind: .string, summary: "笔记标题"),
                V4ToolInputField(name: "body", kind: .string, summary: "笔记正文")
            ]
        ),
        requiresPermission: true,
        permissionScope: .appleNativeApps,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let title = arguments.string(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let body = arguments.string(for: "body")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if title.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`title` 不能为空。",
                messageForDebug: "title empty"
            )
        }
        if body.isEmpty {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`body` 不能为空。",
                messageForDebug: "body empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let title = arguments.string(for: "title") ?? ""
        let body = arguments.string(for: "body") ?? ""

        let creation = await runOsaScript(
            lines: [
                "on run argv",
                "set noteTitle to item 1 of argv",
                "set noteBody to item 2 of argv",
                "tell application \"Notes\""
            ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                "if (count of accounts) is 0 then error \"no notes account\"",
                "set targetAccount to first account",
                "if (count of folders of targetAccount) is 0 then error \"no notes folder\"",
                "set targetFolder to first folder of targetAccount",
                "set createdNote to make new note at targetFolder with properties {name:noteTitle, body:noteBody}",
                "show createdNote",
                "try",
                "return (id of createdNote) as string",
                "on error",
                "return noteTitle",
                "end try",
                "end tell",
                "end run"
            ],
            arguments: [title, body]
        )

        guard creation.exitCode == 0 else {
            throw V4ToolError(
                code: .toolExecutionFailed,
                toolID: spec.toolID,
                messageForUser: "写入 Notes 失败，请检查自动化权限后再试。",
                messageForDebug: creation.detail,
                recoverAction: "open_notes_automation_permission",
                isRetryable: false
            )
        }

        guard let evidence = await resolveNoteEvidence(title: title, body: body, primaryEvidence: creation.stdout) else {
            throw V4ToolError(
                code: .toolExecutionFailed,
                toolID: spec.toolID,
                messageForUser: "Notes 已响应，但没拿到可核验的结果，请再试一次。",
                messageForDebug: "note evidence missing after create; stdout=\(creation.stdout)",
                recoverAction: "retry_command",
                isRetryable: false
            )
        }

        let summary = "已在 Notes 创建笔记《\(title)》。"
        return V4ToolExecutionOutput(
            outputText: summary,
            evidenceSummary: "apple.notes.create \(evidence)",
            rawPayload: .object(
                [
                    "title": .string(title),
                    "bodyPreview": .string(String(body.prefix(80))),
                    "noteID": .string(evidence),
                    "summary": .string(summary)
                ]
            )
        )
    }

    private func resolveNoteEvidence(
        title: String,
        body: String,
        primaryEvidence: String?
    ) async -> String? {
        if let normalized = normalizedNoteEvidence(primaryEvidence) {
            return normalized
        }

        for _ in 0..<5 {
            let verification = await runOsaScript(
                lines: [
                    "on run argv",
                    "set noteTitle to item 1 of argv",
                    "set noteBody to item 2 of argv",
                    "tell application \"Notes\"",
                    "repeat with targetAccount in accounts",
                    "repeat with targetFolder in folders of targetAccount",
                    "repeat with targetNote in notes of targetFolder",
                    "if (name of targetNote is noteTitle) then",
                    "set noteContent to body of targetNote",
                    "if noteContent contains noteBody or noteBody contains noteTitle then",
                    "try",
                    "return (id of targetNote) as string",
                    "on error",
                    "return noteTitle",
                    "end try",
                    "end if",
                    "end if",
                    "end repeat",
                    "end repeat",
                    "end repeat",
                    "end tell",
                    "return \"\"",
                    "end run"
                ],
                arguments: [title, body]
            )
            if
                verification.exitCode == 0,
                let normalized = normalizedNoteEvidence(verification.stdout)
            {
                return normalized
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
        }
        return nil
    }

    private func normalizedNoteEvidence(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
