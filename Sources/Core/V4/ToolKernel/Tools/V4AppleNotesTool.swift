import AppKit
import Foundation

final class V4AppleNotesTool: V4Tool, @unchecked Sendable {
    typealias AppleScriptRunner = @Sendable (
        _ lines: [String],
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval,
        _ maxOutputCharacters: Int
    ) async -> MagicianProcessResult

    private enum Action: String {
        case create
        case append
        case find
    }

    let spec = V4ToolSpec(
        toolName: "apple.notes.create",
        displayName: "备忘录操作",
        summary: "在 Apple Notes 创建、追加或检索备忘录，并返回可核验证据。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, isRequired: false, summary: "原始命令"),
                V4ToolInputField(name: "action", kind: .string, isRequired: false, summary: "create / append / find"),
                V4ToolInputField(name: "title", kind: .string, isRequired: false, summary: "笔记标题（create 或 append）"),
                V4ToolInputField(name: "targetTitle", kind: .string, isRequired: false, summary: "目标标题（append）"),
                V4ToolInputField(name: "body", kind: .string, isRequired: false, summary: "笔记正文（create / append）"),
                V4ToolInputField(name: "query", kind: .string, isRequired: false, summary: "检索关键词（find）")
            ],
            allowsAdditionalFields: true
        ),
        requiresPermission: true,
        permissionScope: .appleNativeApps,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let errorCatalog = V4ToolErrorCatalog()
    private let appleScriptRunner: AppleScriptRunner

    init(
        appleScriptRunner: AppleScriptRunner? = nil
    ) {
        self.appleScriptRunner = appleScriptRunner ?? { lines, arguments, timeoutSeconds, maxOutputCharacters in
            await runOsaScript(
                lines: lines,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                maxOutputCharacters: maxOutputCharacters
            )
        }
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        guard let action = resolvedAction(from: arguments) else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`action` 仅支持 create / append / find。",
                messageForDebug: "notes action invalid"
            )
        }

        switch action {
        case .create:
            let body = arguments.string(for: "body")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if body.isEmpty {
                return V4ToolSemanticValidationFailure(
                    messageForUser: "`body` 不能为空。",
                    messageForDebug: "notes create body empty"
                )
            }
            return nil
        case .append:
            let targetTitle = resolveTargetTitle(from: arguments)
            let body = arguments.string(for: "body")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if targetTitle.isEmpty {
                return V4ToolSemanticValidationFailure(
                    messageForUser: "追加备忘录需要提供目标标题（`targetTitle` 或 `title`）。",
                    messageForDebug: "notes append target title empty"
                )
            }
            if body.isEmpty {
                return V4ToolSemanticValidationFailure(
                    messageForUser: "追加备忘录需要 `body`。",
                    messageForDebug: "notes append body empty"
                )
            }
            return nil
        case .find:
            let query = resolveQuery(from: arguments)
            if query.isEmpty {
                return V4ToolSemanticValidationFailure(
                    messageForUser: "检索备忘录需要 `query` 或 `title`。",
                    messageForDebug: "notes find query empty"
                )
            }
            return nil
        }
    }

    func execute(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        guard let action = resolvedAction(from: arguments) else {
            throw errorCatalog.semanticValidationFailure(
                toolID: spec.toolID,
                failure: V4ToolSemanticValidationFailure(
                    messageForUser: "`action` 仅支持 create / append / find。",
                    messageForDebug: "notes action invalid"
                )
            )
        }
        let body = arguments.string(for: "body")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = resolveCreateTitle(from: arguments, body: body)
        let targetTitle = resolveTargetTitle(from: arguments)
        let query = resolveQuery(from: arguments)
        let command = arguments.string(for: "command") ?? ""

        if magicianIsDryRunCommand(command) {
            let summary: String
            switch action {
            case .create:
                summary = "演练完成：将创建 Notes。"
            case .append:
                summary = "演练完成：将追加 Notes。"
            case .find:
                summary = "演练完成：将检索 Notes。"
            }
            return V4ToolExecutionOutput(
                outputText: summary,
                evidenceSummary: "apple.notes.create action=\(action.rawValue); dry_run=true",
                rawPayload: .object(
                    [
                        "action": .string(action.rawValue),
                        "title": .string(title),
                        "targetTitle": .string(targetTitle),
                        "query": .string(query),
                        "bodyPreview": .string(String(body.prefix(80))),
                        "dryRun": .boolean(true),
                        "summary": .string(summary)
                    ]
                )
            )
        }

        guard MagicianNotesCapability.notesAppAvailable else {
            throw errorCatalog.bridgeNotReady(
                toolID: spec.toolID,
                userMessage: "Notes 不可用，请先打开备忘录后再试。",
                debugMessage: "notes app unavailable",
                recoverAction: "open_notes_app"
            )
        }

        switch action {
        case .create:
            let process = await createNoteViaAppleScript(title: title, body: body)
            guard process.exitCode == 0 else {
                throw makeFailureError(detail: process.detail)
            }
            guard let evidence = await verifyMutatingResult(noteID: process.stdout, expectedTitle: title, expectedBody: body) else {
                throw makeFailureError(detail: "note verification failed after create; raw=\(process.detail)")
            }
            return makeMutatingOutput(
                action: .create,
                title: title,
                body: body,
                evidence: evidence
            )

        case .append:
            let process = await appendNoteViaAppleScript(title: targetTitle, body: body)
            guard process.exitCode == 0 else {
                throw makeFailureError(detail: process.detail)
            }
            guard let evidence = await verifyMutatingResult(noteID: process.stdout, expectedTitle: targetTitle, expectedBody: body) else {
                throw makeFailureError(detail: "note verification failed after append; raw=\(process.detail)")
            }
            return makeMutatingOutput(
                action: .append,
                title: targetTitle,
                body: body,
                evidence: evidence
            )

        case .find:
            let process = await findNotesViaAppleScript(query: query)
            guard process.exitCode == 0 else {
                throw errorCatalog.executionFailure(
                    toolID: spec.toolID,
                    userMessage: "检索 Notes 失败，请稍后再试。",
                    debugMessage: process.detail,
                    recoverAction: "retry_command",
                    isRetryable: false
                )
            }
            let matches = process.stdout
                .split(separator: "\n")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let summary = matches.isEmpty
                ? "未找到匹配的 Notes。"
                : "检索完成，共找到 \(matches.count) 条 Notes。"
            let preview = matches.prefix(8)
            let evidence = "apple.notes.create action=find; query=\(query); matched=\(matches.count)"
            return V4ToolExecutionOutput(
                outputText: summary,
                evidenceSummary: evidence,
                rawPayload: .object(
                    [
                        "action": .string(Action.find.rawValue),
                        "query": .string(query),
                        "matchedCount": .number(Double(matches.count)),
                        "titles": .array(preview.map(V4ToolValue.string)),
                        "summary": .string(summary)
                    ]
                )
            )
        }
    }

    private func resolvedAction(from arguments: V4ToolArguments) -> Action? {
        let raw = arguments.string(for: "action")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if raw.isEmpty {
            return .create
        }
        return Action(rawValue: raw)
    }

    private func resolveCreateTitle(from arguments: V4ToolArguments, body: String) -> String {
        if let explicit = arguments.string(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "PulseType 速记"
        }
        return String(trimmed.prefix(40))
    }

    private func resolveTargetTitle(from arguments: V4ToolArguments) -> String {
        if let explicit = arguments.string(for: "targetTitle")?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let fallback = arguments.string(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }
        return ""
    }

    private func resolveQuery(from arguments: V4ToolArguments) -> String {
        if let explicit = arguments.string(for: "query")?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            return explicit
        }
        if let fallback = arguments.string(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            return fallback
        }
        return ""
    }

    private func makeFailureError(detail: String) -> V4ToolError {
        let recoverAction = magicianLooksLikeAutomationPermissionDenied(detail)
            ? "open_notes_automation_permission"
            : "open_notes_app"
        return errorCatalog.executionFailure(
            toolID: spec.toolID,
            userMessage: "Notes 操作失败，请检查自动化权限后再试。",
            debugMessage: detail,
            recoverAction: recoverAction,
            isRetryable: false
        )
    }

    private func makeMutatingOutput(
        action: Action,
        title: String,
        body: String,
        evidence: String
    ) -> V4ToolExecutionOutput {
        let summary = action == .append ? "已追加 Notes。" : "已写入 Notes。"
        return V4ToolExecutionOutput(
            outputText: summary,
            evidenceSummary: "apple.notes.create action=\(action.rawValue); note_id=\(evidence)",
            rawPayload: .object(
                [
                    "action": .string(action.rawValue),
                    "title": .string(title),
                    "bodyPreview": .string(String(body.prefix(80))),
                    "noteID": .string(evidence),
                    "layer": .string(MagicianAutomationLayer.appleScript.rawValue),
                    "summary": .string(summary)
                ]
            )
        )
    }

    private func createNoteViaAppleScript(
        title: String,
        body: String
    ) async -> MagicianProcessResult {
        await executeAppleScript(
            lines: [
                "on run argv",
                "set noteTitle to item 1 of argv",
                "set noteBody to item 2 of argv",
                "tell application \"Notes\""
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                "if (count of accounts) is 0 then error \"no notes account\"",
                "set targetAccount to first account",
                "if (count of folders of targetAccount) is 0 then error \"no notes folder\"",
                "set targetFolder to first folder of targetAccount",
                "set createdNote to make new note at targetFolder with properties {name:noteTitle, body:noteBody}",
                "return (id of createdNote) as string",
                "end tell",
                "end run"
            ],
            arguments: [title, body]
        )
    }

    private func appendNoteViaAppleScript(
        title: String,
        body: String
    ) async -> MagicianProcessResult {
        await executeAppleScript(
            lines: [
                "on run argv",
                "set noteTitle to item 1 of argv",
                "set noteBody to item 2 of argv",
                "tell application \"Notes\"",
                "set targetNote to missing value",
                "repeat with targetAccount in accounts",
                "repeat with targetFolder in folders of targetAccount",
                "repeat with currentNote in notes of targetFolder",
                "if (name of currentNote as text) is noteTitle then",
                "set targetNote to currentNote",
                "exit repeat",
                "end if",
                "end repeat",
                "if targetNote is not missing value then exit repeat",
                "end repeat",
                "if targetNote is not missing value then exit repeat",
                "end repeat",
                "if targetNote is missing value then error \"note_not_found\"",
                "set body of targetNote to (body of targetNote) & return & noteBody",
                "return (id of targetNote) as string",
                "end tell",
                "end run"
            ],
            arguments: [title, body]
        )
    }

    private func findNotesViaAppleScript(query: String) async -> MagicianProcessResult {
        await executeAppleScript(
            lines: [
                "on run argv",
                "set noteQuery to item 1 of argv",
                "tell application \"Notes\""
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                "set outputLines to {}",
                "repeat with targetAccount in accounts",
                "repeat with targetFolder in folders of targetAccount",
                "repeat with currentNote in notes of targetFolder",
                "set noteName to name of currentNote as text",
                "set noteBody to body of currentNote as text",
                "if noteName contains noteQuery or noteBody contains noteQuery then",
                "set end of outputLines to noteName",
                "end if",
                "end repeat",
                "end repeat",
                "end repeat",
                "return outputLines as text",
                "end tell",
                "end run"
            ],
            arguments: [query]
        )
    }

    private func verifyMutatingResult(
        noteID: String,
        expectedTitle: String,
        expectedBody: String
    ) async -> String? {
        guard let normalizedID = normalizedNoteEvidence(noteID) else {
            return nil
        }
        let bodyNeedle = expectedBody
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let titleNeedle = expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<5 {
            let verification = await executeAppleScript(
                lines: [
                    "on run argv",
                    "set expectedID to item 1 of argv",
                    "set expectedTitle to item 2 of argv",
                    "set expectedBodyNeedle to item 3 of argv",
                    "tell application \"Notes\"",
                    "repeat with targetAccount in accounts",
                    "repeat with targetFolder in folders of targetAccount",
                    "repeat with targetNote in notes of targetFolder",
                    "set currentID to \"\"",
                    "try",
                    "set currentID to (id of targetNote) as string",
                    "end try",
                    "if currentID is expectedID then",
                    "set currentTitle to (name of targetNote) as string",
                    "set noteContent to body of targetNote",
                    "if (currentTitle is expectedTitle) and (noteContent contains expectedBodyNeedle) then",
                    "return currentID",
                    "end if",
                    "end repeat",
                    "end repeat",
                    "end repeat",
                    "end tell",
                    "return \"\"",
                    "end run"
                ],
                arguments: [normalizedID, titleNeedle, String(bodyNeedle.prefix(80))]
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

    private func executeAppleScript(
        lines: [String],
        arguments: [String],
        timeoutSeconds: TimeInterval = 12,
        maxOutputCharacters: Int = 4_000
    ) async -> MagicianProcessResult {
        await appleScriptRunner(lines, arguments, timeoutSeconds, maxOutputCharacters)
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
