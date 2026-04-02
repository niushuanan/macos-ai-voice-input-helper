import AppKit
import Foundation

final class V4AppleNotesTool: V4Tool, @unchecked Sendable {
    typealias AppleScriptRunner = @Sendable (
        _ lines: [String],
        _ arguments: [String],
        _ timeoutSeconds: TimeInterval,
        _ maxOutputCharacters: Int
    ) async -> MagicianProcessResult
    typealias ShortcutRunner = @Sendable (
        _ name: String,
        _ inputText: String?,
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
    private let shortcutRunner: ShortcutRunner
    private let shortcutSupport: MagicianCreateNoteShortcutSupport
    private let shortcutAvailability: () -> Bool

    init(
        appleScriptRunner: AppleScriptRunner? = nil,
        shortcutRunner: ShortcutRunner? = nil,
        shortcutSupport: MagicianCreateNoteShortcutSupport = MagicianCreateNoteShortcutSupport(),
        shortcutAvailability: (() -> Bool)? = nil
    ) {
        self.appleScriptRunner = appleScriptRunner ?? { lines, arguments, timeoutSeconds, maxOutputCharacters in
            await runOsaScript(
                lines: lines,
                arguments: arguments,
                timeoutSeconds: timeoutSeconds,
                maxOutputCharacters: maxOutputCharacters
            )
        }
        self.shortcutRunner = shortcutRunner ?? { name, inputText, timeoutSeconds, maxOutputCharacters in
            await runShortcut(
                name: name,
                inputText: inputText,
                timeoutSeconds: timeoutSeconds,
                maxOutputCharacters: maxOutputCharacters
            )
        }
        self.shortcutSupport = shortcutSupport
        self.shortcutAvailability = shortcutAvailability ?? {
            shortcutSupport.cliAvailable && shortcutSupport.hasShortcut()
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
            let createResult = await runCreateChain(title: title, body: body)
            guard let evidence = createResult.evidence else {
                let detail = magicianAutomationDebugSummary(from: createResult.attempts)
                throw makeFailureError(
                    detail: "note verification failed after create; \(detail)",
                    attempts: createResult.attempts
                )
            }
            return makeMutatingOutput(
                action: .create,
                title: title,
                body: body,
                evidence: evidence,
                layer: createResult.layer
            )

        case .append:
            let process = await appendNoteViaAppleScript(title: targetTitle, body: body)
            guard process.exitCode == 0 else {
                throw makeFailureError(detail: process.detail, attempts: [])
            }
            guard let evidence = await verifyMutatingResult(noteID: process.stdout, expectedTitle: targetTitle, expectedBody: body) else {
                throw makeFailureError(
                    detail: "note verification failed after append; raw=\(process.detail)",
                    attempts: []
                )
            }
            return makeMutatingOutput(
                action: .append,
                title: targetTitle,
                body: body,
                evidence: evidence,
                layer: .appleScript
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

    private func makeFailureError(detail: String, attempts: [MagicianAutomationAttempt]) -> V4ToolError {
        let allDetails = ([detail] + attempts.map(\.detail)).joined(separator: " | ")
        let recoverAction: String
        if magicianLooksLikeAutomationPermissionDenied(allDetails) {
            recoverAction = "open_notes_automation_permission"
        } else if allDetails.lowercased().contains("shortcut not found") {
            recoverAction = "create_note_shortcut"
        } else if allDetails.lowercased().contains("shortcuts cli unavailable") {
            recoverAction = "open_shortcuts"
        } else {
            recoverAction = "open_notes_app"
        }
        return errorCatalog.executionFailure(
            toolID: spec.toolID,
            userMessage: "Notes 操作失败：\(detail)",
            debugMessage: attempts.isEmpty
                ? detail
                : "\(detail) | attempts=\(magicianAutomationDebugSummary(from: attempts))",
            recoverAction: recoverAction,
            isRetryable: false
        )
    }

    private func makeMutatingOutput(
        action: Action,
        title: String,
        body: String,
        evidence: String,
        layer: MagicianAutomationLayer
    ) -> V4ToolExecutionOutput {
        let summary = action == .append
            ? "已追加 Notes（\(layer.rawValue)）。"
            : "已写入 Notes（\(layer.rawValue)）。"
        return V4ToolExecutionOutput(
            outputText: summary,
            evidenceSummary: "apple.notes.create action=\(action.rawValue); note_id=\(evidence)",
            rawPayload: .object(
                [
                    "action": .string(action.rawValue),
                    "title": .string(title),
                    "bodyPreview": .string(String(body.prefix(80))),
                    "noteID": .string(evidence),
                    "layer": .string(layer.rawValue),
                    "summary": .string(summary)
                ]
            )
        )
    }

    private struct CreateChainResult {
        let layer: MagicianAutomationLayer
        let evidence: String?
        let attempts: [MagicianAutomationAttempt]
    }

    private func runCreateChain(title: String, body: String) async -> CreateChainResult {
        let steps = createAutomationSteps(title: title, body: body)
        var attempts: [MagicianAutomationAttempt] = []
        var succeededLayer: MagicianAutomationLayer?
        var succeededResult: MagicianProcessResult?

        for step in steps {
            let startedAt = Date()
            let result = await step.run()
            let durationMS = Int(Date().timeIntervalSince(startedAt) * 1_000)
            attempts.append(
                MagicianAutomationAttempt(
                    layer: step.layer,
                    exitCode: result.exitCode,
                    durationMS: durationMS,
                    detail: result.detail
                )
            )
            if step.success(result) {
                succeededLayer = step.layer
                succeededResult = result
                break
            }
        }

        guard let layer = succeededLayer, let processResult = succeededResult else {
            return CreateChainResult(
                layer: attempts.last?.layer ?? .appleScript,
                evidence: nil,
                attempts: attempts
            )
        }

        switch layer {
        case .appleScript:
            let evidence = await verifyMutatingResult(
                noteID: processResult.stdout,
                expectedTitle: title,
                expectedBody: body
            )
            return CreateChainResult(layer: .appleScript, evidence: evidence, attempts: attempts)
        case .shortcuts:
            if let noteID = extractNoteID(from: processResult.stdout) {
                return CreateChainResult(layer: .shortcuts, evidence: noteID, attempts: attempts)
            }
            if let noteID = await findNoteIDByTitleAndBody(title: title, body: body) {
                return CreateChainResult(layer: .shortcuts, evidence: noteID, attempts: attempts)
            }
            return CreateChainResult(layer: .shortcuts, evidence: nil, attempts: attempts)
        default:
            return CreateChainResult(layer: layer, evidence: nil, attempts: attempts)
        }
    }

    private func createAutomationSteps(title: String, body: String) -> [MagicianAutomationStep] {
        var steps: [MagicianAutomationStep] = [
            MagicianAutomationStep(
                layer: .appleScript,
                run: { await self.createNoteViaAppleScript(title: title, body: body) },
                success: { result in
                    result.exitCode == 0 && self.extractNoteID(from: result.stdout) != nil
                }
            )
        ]
        if shortcutAvailability() {
            steps.append(
                MagicianAutomationStep(
                    layer: .shortcuts,
                    run: { await self.createNoteViaShortcut(title: title, body: body) },
                    success: { result in result.exitCode == 0 }
                )
            )
        }
        return steps
    }

    private func createNoteViaShortcut(title: String, body: String) async -> MagicianProcessResult {
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = content.isEmpty ? title : "\(title)\n\n\(content)"
        return await shortcutRunner(shortcutSupport.shortcutName, input, 12, 4_000)
    }

    private func extractNoteID(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }
        if let match = text.range(of: #"x-coredata://[^\s]+"#, options: .regularExpression) {
            return String(text[match])
        }
        if text.lowercased().contains("note_id=") || text.lowercased().contains("note-id=") {
            return text
        }
        return normalizedNoteEvidence(text)
    }

    private func findNoteIDByTitleAndBody(title: String, body: String) async -> String? {
        let titleNeedle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyNeedle = body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        guard !titleNeedle.isEmpty else {
            return nil
        }
        let process = await executeAppleScript(
            lines: [
                "on run argv",
                "set expectedTitle to item 1 of argv",
                "set expectedBodyNeedle to item 2 of argv",
                "tell application \"Notes\"",
                "repeat with targetAccount in accounts",
                "repeat with targetFolder in folders of targetAccount",
                "repeat with targetNote in notes of targetFolder",
                "set currentTitle to (name of targetNote) as string",
                "if currentTitle is expectedTitle then",
                "set noteBody to body of targetNote",
                "if expectedBodyNeedle is \"\" or noteBody contains expectedBodyNeedle then",
                "return (id of targetNote) as string",
                "end if",
                "end if",
                "end repeat",
                "end repeat",
                "end repeat",
                "end tell",
                "return \"\"",
                "end run"
            ],
            arguments: [titleNeedle, String(bodyNeedle.prefix(80))]
        )
        guard process.exitCode == 0 else {
            return nil
        }
        return extractNoteID(from: process.stdout)
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
                "set targetAccount to missing value",
                "repeat with candidateAccount in accounts",
                "if (count of folders of candidateAccount) > 0 then",
                "set targetAccount to candidateAccount",
                "exit repeat",
                "end if",
                "end repeat",
                "if targetAccount is missing value then",
                "set targetAccount to first account",
                "end if",
                "if (count of folders of targetAccount) is 0 then",
                "make new folder at targetAccount with properties {name:\"Notes\"}",
                "end if",
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
        let expectedTitleNormalized = normalizeVerificationText(expectedTitle)
        let expectedBodyNormalized = normalizeVerificationText(expectedBody)

        for _ in 0..<15 {
            if let noteSnapshot = await fetchNoteSnapshot(noteID: normalizedID) {
                if matchesExpectedNote(
                    snapshot: noteSnapshot,
                    expectedTitle: expectedTitleNormalized,
                    expectedBody: expectedBodyNormalized
                ) {
                    return normalizedID
                }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private struct NoteSnapshot {
        let noteID: String
        let title: String
        let body: String
    }

    private func fetchNoteSnapshot(noteID: String) async -> NoteSnapshot? {
        let verification = await executeAppleScript(
            lines: [
                "on run argv",
                "set expectedID to item 1 of argv",
                "tell application \"Notes\"",
                "repeat with targetAccount in accounts",
                "repeat with targetFolder in folders of targetAccount",
                "repeat with targetNote in notes of targetFolder",
                "set currentID to \"\"",
                "try",
                "set currentID to (id of targetNote) as string",
                "end try",
                "if currentID is expectedID then",
                "set currentTitle to \"\"",
                "set noteContent to \"\"",
                "try",
                "set currentTitle to (name of targetNote) as string",
                "end try",
                "try",
                "set noteContent to (body of targetNote) as string",
                "end try",
                "return currentID & (ASCII character 31) & currentTitle & (ASCII character 30) & noteContent",
                "end if",
                "end repeat",
                "end repeat",
                "end repeat",
                "end tell",
                "return \"\"",
                "end run"
            ],
            arguments: [noteID]
        )
        guard verification.exitCode == 0 else {
            return nil
        }
        let raw = verification.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return nil
        }
        let parts = raw.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        let normalizedID = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let titleAndBody = String(parts[1])
        let titleBodyParts = titleAndBody.split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false)
        let title = titleBodyParts.isEmpty ? "" : String(titleBodyParts[0])
        let body = titleBodyParts.count > 1 ? String(titleBodyParts[1]) : ""
        guard !normalizedID.isEmpty else {
            return nil
        }
        return NoteSnapshot(noteID: normalizedID, title: title, body: body)
    }

    private func matchesExpectedNote(
        snapshot: NoteSnapshot,
        expectedTitle: String,
        expectedBody: String
    ) -> Bool {
        guard !snapshot.noteID.isEmpty else {
            return false
        }

        if !expectedTitle.isEmpty {
            let currentTitle = normalizeVerificationText(snapshot.title)
            if currentTitle != expectedTitle {
                return false
            }
        }

        guard !expectedBody.isEmpty else {
            return true
        }

        let currentBody = normalizeVerificationText(snapshot.body)
        guard !currentBody.isEmpty else {
            return false
        }
        if currentBody.contains(expectedBody) {
            return true
        }
        let expectedPrefix = String(expectedBody.prefix(120))
        if !expectedPrefix.isEmpty, currentBody.contains(expectedPrefix) {
            return true
        }
        return false
    }

    private func normalizeVerificationText(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "\r\n", with: "\n")
        value = value.replacingOccurrences(of: "\r", with: "\n")
        value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entityMap: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'"
        ]
        for (entity, replacement) in entityMap {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
