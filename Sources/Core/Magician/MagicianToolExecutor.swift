import AppKit
import EventKit
import Foundation

@MainActor
protocol MagicianToolExecuting {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult
}

@MainActor
protocol MagicianMailExecuting {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult
}

@MainActor
// legacy executor: 仅供旧 runtime 兜底使用。V4 起不要继续往这里加新能力。
final class MagicianToolExecutor: MagicianToolExecuting {
    private let eventAdapter = MagicianEventAdapter()
    private let noteAdapter = MagicianNoteAdapter()
    private let musicAdapter = MagicianMusicAdapter()
    private let providerSettingsStore: ProviderSettingsStore?
    private let mailAdapter: any MagicianMailExecuting
    private let cliRegistry: MagicianCLIRegistry

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        mailAddressBookStore: MailAddressBookStore? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        mailAdapter: (any MagicianMailExecuting)? = nil,
        cliRegistry: MagicianCLIRegistry = MagicianCLIRegistry()
    ) {
        self.providerSettingsStore = providerSettingsStore
        let resolvedMailAddressBookStore = mailAddressBookStore ?? MailAddressBookStore()
        self.mailAdapter = mailAdapter ?? MagicianMailAdapter(
            addressBookStore: resolvedMailAddressBookStore,
            providerSettingsStore: providerSettingsStore,
            generationProvider: generationProvider
        )
        self.cliRegistry = cliRegistry
    }

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        switch intent.intent {
        case .textTransform:
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "文字处理应该走改写链路，当前执行器不处理这个动作。",
                debugMessage: "textTransform routed to MagicianToolExecutor",
                recoverAction: "check_router_logic"
            )
        case .createEvent:
            return try await eventAdapter.execute(intent: intent, context: context)
        case .createNote:
            return try await noteAdapter.execute(intent: intent, context: context)
        case .composeEmailDraft:
            return try await mailAdapter.execute(intent: intent, context: context)
        case .controlMusic:
            return try await musicAdapter.execute(intent: intent, context: context)
        case .feishuCLI:
            return try await executeFeishuCLI(intent: intent, context: context)
        }
    }

    private func executeFeishuCLI(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        let commandText = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let operationRaw = intent.params.cliOperation?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let operation = FeishuCanonicalOperation(rawValue: operationRaw)
            ?? FeishuCanonicalOperation.infer(from: commandText)

        guard let operation else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没识别到可执行的飞书动作，请补一句更具体的命令。",
                debugMessage: "feishu cli operation unresolved",
                recoverAction: "retry_command"
            )
        }

        let explicitArguments = intent.params.cliArguments ?? []
        let availability = cliRegistry.currentFeishuAvailability(
            executableOverride: providerSettingsStore?.resolvedFeishuCLIExecutablePathOverride
        )
        let result = await cliRegistry.executeFeishu(
            operation: operation,
            spokenCommand: commandText,
            explicitArguments: explicitArguments,
            availability: availability
        )

        switch result {
        case let .success(success):
            return success
        case let .failure(error):
            throw error
        }
    }
}

struct MagicianProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var detail: String {
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedStderr.isEmpty {
            return trimmedStderr
        }
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedStdout.isEmpty ? "unknown" : trimmedStdout
    }
}

func runProcess(
    executablePath: String,
    arguments: [String]
) async -> MagicianProcessResult {
    await Task.detached(priority: .userInitiated) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return MagicianProcessResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription
            )
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return MagicianProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }.value
}

func runOsaScript(
    lines: [String],
    arguments: [String]
) async -> MagicianProcessResult {
    var commandArguments: [String] = []
    for line in lines {
        commandArguments.append("-e")
        commandArguments.append(line)
    }
    commandArguments.append("--")
    commandArguments.append(contentsOf: arguments)
    return await runProcess(
        executablePath: "/usr/bin/osascript",
        arguments: commandArguments
    )
}

func magicianEnsureApplicationReadyAppleScriptLines(
    activate: Bool = true,
    timeoutSeconds: Int = 8
) -> [String] {
    var lines = [
        "set startupDeadline to (current date) + \(timeoutSeconds)",
        "if not running then launch",
        "repeat while (not running) and ((current date) < startupDeadline)",
        "delay 0.1",
        "end repeat",
        "if not running then error \"app launch timeout\""
    ]
    if activate {
        lines.append("activate")
        // Let the UI settle before sending follow-up commands.
        lines.append("delay 0.1")
    }
    return lines
}

private struct MagicianEventAdapter {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        let eventStore = EKEventStore()

        let status = EKEventStore.authorizationStatus(for: .event)
        if !hasCalendarAccess(status) {
            let granted: Bool
            if status == .notDetermined {
                granted = await requestCalendarAccess(eventStore: eventStore)
            } else {
                granted = false
            }
            guard granted else {
                throw MagicianError(
                    code: .permissionDenied,
                    userMessage: "缺少日历权限，请到系统设置打开后再试。",
                    debugMessage: "calendar permission denied",
                    recoverAction: "open_calendar_permission_settings"
                )
            }
        }

        guard let calendar = eventStore.defaultCalendarForNewEvents else {
            throw MagicianError(
                code: .eventCreateFailed,
                userMessage: "当前没有可用日历，请先在系统日历里添加账号。",
                debugMessage: "defaultCalendarForNewEvents nil",
                recoverAction: "configure_calendar_account"
            )
        }

        let title = resolvedTitle(intent: intent, context: context)
        let location = intent.params.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let startAt = resolvedStartDate(intent: intent, context: context) else {
            throw MagicianError(
                code: .eventCreateFailed,
                userMessage: "未识别到明确时间，请补充具体日期和时间。",
                debugMessage: "event start date unresolved",
                recoverAction: "retry_command"
            )
        }
        let endAt = resolvedEndDate(intent: intent, startAt: startAt)

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.location = location
        event.startDate = startAt
        event.endDate = endAt
        event.notes = resolvedEventNotes(intent: intent, context: context)

        do {
            try eventStore.save(event, span: .thisEvent)
        } catch {
            throw MagicianError(
                code: .eventCreateFailed,
                userMessage: "建日程失败，请稍后再试。",
                debugMessage: "EKEventStore save failed: \(error.localizedDescription)",
                recoverAction: "retry_later"
            )
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let summary = "\(title)（\(formatter.string(from: startAt)) - \(formatter.string(from: endAt))）"
        return MagicianExecutionResult(
            intent: .createEvent,
            userMessage: "已建日程：\(summary)",
            outputText: summary,
            historyDisplayText: "已建日程：\(summary)",
            fallbackUsed: false,
            observation: MagicianAgentObservation(
                verificationStatus: .verified,
                targetSummary: title,
                evidenceSummary: "eventIdentifier=\(event.eventIdentifier ?? "missing")"
            )
        )
    }

    private func hasCalendarAccess(_ status: EKAuthorizationStatus) -> Bool {
        status == .fullAccess || status == .writeOnly
    }

    private func requestCalendarAccess(eventStore: EKEventStore) async -> Bool {
        await withCheckedContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    private func resolvedTitle(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let selected = context.selectedText
        let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            let title = intent.params.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            if
                !selected.isEmpty,
                isLikelyInstructionPhrase(
                    title,
                    command: command,
                    actionTokens: ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event"]
                )
            {
                return String(selected.prefix(20))
            }
            return String(title.prefix(60))
        }

        if let payload = magicianResolvedPayload(
            selectedText: selected,
            sourceText: intent.sourceText,
            command: command,
            actionTokens: ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event", "安排", "提醒"]
        ) {
            return String(payload.prefix(20))
        }
        return "新建日程"
    }

    private func resolvedStartDate(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> Date? {
        if
            let startString = intent.params.startAt,
            let date = parseISO8601(startString)
        {
            return date
        }

        let detectorInput = "\(context.command)\n\(context.selectedText)\n\(intent.sourceText)"
        if let detected = detectDate(in: detectorInput) {
            return detected
        }
        return nil
    }

    private func resolvedEndDate(
        intent: MagicianIntent,
        startAt: Date
    ) -> Date {
        if
            let endString = intent.params.endAt,
            let date = parseISO8601(endString),
            date > startAt
        {
            return date
        }
        return startAt.addingTimeInterval(60 * 60)
    }

    private func resolvedEventNotes(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let actionTokens = ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event", "安排", "提醒"]
        let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let extractedNotes = intent.params.notes?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if
            !extractedNotes.isEmpty,
            !isLikelyInstructionPhrase(
                extractedNotes,
                command: command,
                actionTokens: actionTokens
            )
        {
            return extractedNotes
        }

        return magicianResolvedPayload(
            selectedText: context.selectedText,
            sourceText: intent.sourceText,
            command: command,
            actionTokens: actionTokens
        ) ?? ""
    }

    private func parseISO8601(_ value: String) -> Date? {
        if let value = isoWithFractional.date(from: value) {
            return value
        }
        return iso.date(from: value)
    }

    private func detectDate(in text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return detector.matches(in: text, options: [], range: range).first?.date
    }

    private let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct MagicianNoteAdapter {
    private let shortcutSupport = MagicianCreateNoteShortcutSupport()

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        let noteBody = resolvedNoteBody(intent: intent, context: context)
        guard !noteBody.isEmpty else {
            throw MagicianError(
                code: .selectionEmpty,
                userMessage: "备忘录内容为空，请补一句要记的内容再试。",
                debugMessage: "note body empty",
                recoverAction: "retry_command"
            )
        }

        let noteTitle = resolvedNoteTitle(intent: intent, context: context, noteBody: noteBody)
        var notesScriptDetail: String?
        if MagicianNotesCapability.notesAppAvailable {
            let notesResult = await createNoteViaAppleScript(
                title: noteTitle,
                body: noteBody
            )
            if notesResult.exitCode == 0 {
                guard
                    let evidence = await resolveVerifiedNoteEvidence(
                        title: noteTitle,
                        body: noteBody,
                        primaryEvidence: notesResult.stdout
                    )
                else {
                    throw MagicianError(
                        code: .toolExecutionFailed,
                        userMessage: "备忘录写入结果无法核验，已判定失败。",
                        debugMessage: "notes applescript succeeded but evidence missing; stdout=\(notesResult.stdout)",
                        recoverAction: "retry_command"
                    )
                }
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已写入 Notes。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: false,
                    observation: MagicianAgentObservation(
                        verificationStatus: .verified,
                        targetSummary: noteTitle,
                        evidenceSummary: evidence
                    )
                )
            }
            notesScriptDetail = notesResult.detail
        }

        let shortcutName = shortcutSupport.shortcutName
        let shortcutExists = shortcutSupport.hasShortcut(named: shortcutName)
        if shortcutSupport.cliAvailable, shortcutExists {
            let result = try await runShortcut(name: shortcutName, inputText: noteBody)
            if result.exitCode == 0 {
                guard
                    let evidence = await resolveVerifiedNoteEvidence(
                        title: noteTitle,
                        body: noteBody,
                        primaryEvidence: result.stdout
                    )
                else {
                    throw MagicianError(
                        code: .toolExecutionFailed,
                        userMessage: "快捷指令已触发，但备忘录写入结果无法核验，已判定失败。",
                        debugMessage: "shortcuts cli succeeded but evidence missing; stdout=\(result.stdout)",
                        recoverAction: "retry_command"
                    )
                }
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已提交到备忘录快捷指令。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: notesScriptDetail != nil,
                    observation: MagicianAgentObservation(
                        verificationStatus: .verified,
                        targetSummary: noteTitle,
                        evidenceSummary: evidence
                    )
                )
            }

            let detail = result.detail
            let lowered = detail.lowercased()
            if lowered.contains("not found") || lowered.contains("could not find") {
                throw MagicianError(
                    code: .shortcutNotFound,
                    userMessage: "没找到快捷指令“\(shortcutName)”。请先在 Shortcuts 创建同名指令。",
                    debugMessage: detail,
                    recoverAction: "create_note_shortcut"
                )
            }

            if runShortcutViaURLScheme(name: shortcutName, inputText: noteBody) {
                guard
                    let evidence = await resolveVerifiedNoteEvidence(
                        title: noteTitle,
                        body: noteBody,
                        primaryEvidence: nil
                    )
                else {
                    throw MagicianError(
                        code: .toolExecutionFailed,
                        userMessage: "Shortcuts URL 已触发，但备忘录写入结果无法核验，已判定失败。",
                        debugMessage: "shortcuts url fallback triggered but evidence missing",
                        recoverAction: "retry_command"
                    )
                }
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "CLI 执行失败，已改用 Shortcuts URL 触发并完成写入。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: true,
                    observation: MagicianAgentObservation(
                        verificationStatus: .verified,
                        targetSummary: noteTitle,
                        evidenceSummary: evidence,
                        autoRepairApplied: true
                    )
                )
            }

            let notesHint = notesScriptDetail.map { "Notes 直写失败：\($0)" } ?? "Notes 直写不可用。"
            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "写入备忘录失败，请检查 Notes 自动化权限或 Shortcuts 配置后再试。",
                debugMessage: "\(notesHint) Shortcuts 失败：\(detail)",
                recoverAction: "retry_later"
            )
        }

        if runShortcutViaURLScheme(name: shortcutName, inputText: noteBody) {
            guard
                let evidence = await resolveVerifiedNoteEvidence(
                    title: noteTitle,
                    body: noteBody,
                    primaryEvidence: nil
                )
            else {
                throw MagicianError(
                    code: .toolExecutionFailed,
                    userMessage: "Shortcuts URL 已触发，但备忘录写入结果无法核验，已判定失败。",
                    debugMessage: "shortcuts url succeeded but evidence missing",
                    recoverAction: "retry_command"
                )
            }
            return MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已通过 Shortcuts URL 触发并完成写入。",
                outputText: noteBody,
                historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                fallbackUsed: true,
                observation: MagicianAgentObservation(
                    verificationStatus: .verified,
                    targetSummary: noteTitle,
                    evidenceSummary: evidence,
                    autoRepairApplied: true
                )
            )
        }

        let noteDetail = notesScriptDetail ?? "Notes 直写未执行。"
        let shortcutDetail = shortcutSupport.cliAvailable
            ? "没找到快捷指令“\(shortcutName)”。"
            : "系统里没有可用的 shortcuts 命令。"
        throw MagicianError(
            code: shortcutSupport.cliAvailable ? .shortcutNotFound : .toolExecutionFailed,
            userMessage: "写入备忘录失败，请先打开 Notes，或在 Shortcuts 配置“\(shortcutName)”后再试。",
            debugMessage: "\(noteDetail) \(shortcutDetail)",
            recoverAction: shortcutSupport.cliAvailable ? "create_note_shortcut" : "open_shortcuts"
        )
    }

    private func resolveVerifiedNoteEvidence(
        title: String,
        body: String,
        primaryEvidence: String?
    ) async -> String? {
        if let evidence = normalizedStructuredNoteEvidence(primaryEvidence) {
            return evidence
        }
        for attempt in 0..<5 {
            if let evidence = await resolvedNoteEvidence(title: title, body: body) {
                return evidence
            }
            if attempt < 4 {
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
        }
        return nil
    }

    private func normalizedStructuredNoteEvidence(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return nil
        }
        let lowered = value.lowercased()
        guard lowered.contains("x-coredata://") || lowered.contains("note-id=") else {
            return nil
        }
        return value
    }

    private func resolvedNoteBody(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let selected = context.selectedText
        let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = intent.params.noteBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty {
            if
                !selected.isEmpty,
                isLikelyInstructionPhrase(
                    body,
                    command: command,
                    actionTokens: ["备忘录", "写进备忘录", "写入备忘录", "记到", "记下来", "note"]
                )
            {
                return selected
            }
            return body
        }
        return magicianResolvedPayload(
            selectedText: selected,
            sourceText: intent.sourceText,
            command: command,
            actionTokens: ["备忘录", "写进备忘录", "写入备忘录", "记到", "记下来", "note", "记录"]
        ) ?? ""
    }

    private func resolvedNoteTitle(
        intent: MagicianIntent,
        context: MagicianExecutionContext,
        noteBody: String
    ) -> String {
        if
            let title = intent.params.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return String(title.prefix(40))
        }

        let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let semanticTitle = magicianSemanticPayload(
            from: command,
            actionTokens: ["备忘录", "写进备忘录", "写入备忘录", "记到", "记下来", "note", "记录"]
        ) {
            return String(semanticTitle.prefix(40))
        }

        let preview = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return String(preview.prefix(40))
        }
        return "PulseType 速记"
    }

    private func runShortcut(
        name: String,
        inputText: String
    ) async throws -> MagicianProcessResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magician-note-\(UUID().uuidString)")
            .appendingPathExtension("txt")

        try inputText.write(to: tempURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return await runProcess(
            executablePath: MagicianCreateNoteShortcutSupport.shortcutsExecutablePath,
            arguments: ["run", name, "--input-path", tempURL.path]
        )
    }

    private func runShortcutViaURLScheme(
        name: String,
        inputText: String
    ) -> Bool {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: inputText)
        ]

        guard let url = components.url else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func createNoteViaAppleScript(
        title: String,
        body: String
    ) async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "on run argv",
                "set noteTitle to item 1 of argv",
                "set noteBody to item 2 of argv",
                "tell application \"Notes\"",
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
    }

    private func resolvedNoteEvidence(
        title: String,
        body: String
    ) async -> String? {
        let result = await runOsaScript(
            lines: [
                "on run argv",
                "set noteTitle to item 1 of argv",
                "set noteBody to item 2 of argv",
                "tell application \"Notes\"",
                "repeat with targetAccount in accounts",
                "repeat with targetFolder in folders of targetAccount",
                "repeat with targetNote in notes of targetFolder",
                "set titleMatches to (name of targetNote is noteTitle)",
                "if titleMatches then",
                "set noteContent to body of targetNote",
                "if noteContent contains noteBody or noteBody contains (name of targetNote) then",
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
        guard result.exitCode == 0 else {
            return nil
        }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedStructuredNoteEvidence(output)
    }
}

private struct MagicianMusicAdapter {
    private struct ParsedIntent {
        let action: Action
        let extractedQuery: String?
    }

    private enum Action {
        case play(query: String?)
        case pause
        case resume
        case next
        case previous

        var userMessage: String {
            switch self {
            case let .play(query):
                if let query, !query.isEmpty {
                    return "已开始播放：\(query)"
                }
                return "已开始播放音乐。"
            case .pause:
                return "已暂停播放。"
            case .resume:
                return "已继续播放。"
            case .next:
                return "已切到下一首。"
            case .previous:
                return "已切回上一首。"
            }
        }
    }

    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) async throws -> MagicianExecutionResult {
        guard MagicianMusicCapability.musicAppAvailable else {
            throw MagicianError(
                code: .musicUnavailable,
                userMessage: "Music 不可用，请先打开音乐应用。",
                debugMessage: "music app unavailable",
                recoverAction: "open_music_app"
            )
        }

        let action = resolvedAction(intent: intent, context: context)
        let warmup = await warmupMusicLibrary()
        guard warmup.exitCode == 0 else {
            throw MagicianError(
                code: .musicControlFailed,
                userMessage: "Music 启动失败，请确认应用可正常打开后再试。",
                debugMessage: warmup.detail,
                recoverAction: "open_music_app"
            )
        }
        let result = await runAction(action)
        guard result.exitCode == 0 else {
            throw MagicianError(
                code: .musicControlFailed,
                userMessage: "音乐控制失败，请确认 Music 已启动且曲库可访问后再试。",
                debugMessage: result.detail,
                recoverAction: "open_music_app"
            )
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if case let .play(query?) = action {
            if output == "track_not_found" {
                throw MagicianError(
                    code: .musicControlFailed,
                    userMessage: "未在 Music 搜索里找到这首歌，请确认歌名后再试。",
                    debugMessage: "no matched track for query: \(query) (via Music search UI)",
                    recoverAction: "open_music_app"
                )
            }
            guard output.hasPrefix("track=") else {
                throw MagicianError(
                    code: .musicControlFailed,
                    userMessage: "音乐已触发播放，但没拿到曲目证据，请重试。",
                    debugMessage: "music output missing track evidence; query=\(query); output=\(output)",
                    recoverAction: "retry_command"
                )
            }
            // Simple verification: compare the played track name with the requested song title.
            if let played = parseMusicEvidence(output),
               let expectedTitle = expectedSongTitle(from: query),
               !playedTrackTitleMatchesExpected(played.track, expectedTitle: expectedTitle) {
                throw MagicianError(
                    code: .musicControlFailed,
                    userMessage: "当前播放曲目与请求不一致，已判定失败。",
                    debugMessage: "query=\(query) output=\(output)",
                    recoverAction: "retry_command"
                )
            }
        }
        let evidence = output.isEmpty ? "Music action done" : output
        let verificationStatus: MagicianAgentVerificationStatus
        if case .play = action {
            verificationStatus = output.hasPrefix("track=") ? .verified : .assumed
        } else {
            verificationStatus = .verified
        }

        // Prefer the actual played track title in the user-facing message.
        let resolvedMessage: String = {
            guard case .play = action else {
                return action.userMessage
            }
            guard let played = parseMusicEvidence(output) else {
                return action.userMessage
            }
            if let artist = played.artist, !artist.isEmpty {
                return "已开始播放：\(artist) - \(played.track)"
            }
            return "已开始播放：\(played.track)"
        }()
        return MagicianExecutionResult(
            intent: .controlMusic,
            userMessage: resolvedMessage,
            outputText: output.isEmpty ? nil : output,
            historyDisplayText: resolvedMessage,
            fallbackUsed: false,
            observation: MagicianAgentObservation(
                verificationStatus: verificationStatus,
                evidenceSummary: evidence
            )
        )
    }

    private func resolvedAction(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> Action {
        let parsed = parseMusicIntent(from: context.command)
        if case let .play(query) = parsed.action, let query, !query.isEmpty {
            return .play(query: query)
        }

        if let source = normalizedPlayableQuery(intent.sourceText) {
            return .play(query: source)
        }
        return parsed.action
    }

    private func runAction(_ action: Action) async -> MagicianProcessResult {
        switch action {
        case let .play(query):
            if let query, !query.isEmpty {
                return await runPlayAction(query: query)
            }
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                    "play",
                    "return \"state=play\"",
                    "end tell"
                ],
                arguments: []
            )
        case .pause:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "pause",
                    "return \"state=pause\"",
                    "end tell"
                ],
                arguments: []
            )
        case .resume:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "play",
                    "return \"state=resume\"",
                    "end tell"
                ],
                arguments: []
            )
        case .next:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "next track",
                    "return \"state=next\"",
                    "end tell"
                ],
                arguments: []
            )
        case .previous:
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "previous track",
                    "return \"state=previous\"",
                    "end tell"
                ],
                arguments: []
            )
        }
    }

    private func warmupMusicLibrary() async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false, timeoutSeconds: 12) + [
                "set ready to false",
                "repeat with idx from 1 to 12",
                "try",
                "set _count to (count of tracks of library playlist 1)",
                "set ready to true",
                "exit repeat",
                "on error",
                "delay 0.12",
                "end try",
                "end repeat",
                "if ready then",
                "return \"library_ready\"",
                "end if",
                "return \"library_pending\"",
                "end tell"
            ],
            arguments: []
        )
    }

    private func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains { value.contains($0) }
    }

    private func parseMusicIntent(from command: String) -> ParsedIntent {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = normalized.lowercased()

        if containsAny(lowered, keywords: ["暂停", "pause", "停止播放", "停一下"]) {
            return ParsedIntent(action: .pause, extractedQuery: nil)
        }
        if containsAny(lowered, keywords: ["继续", "恢复", "resume", "继续播放"]) {
            return ParsedIntent(action: .resume, extractedQuery: nil)
        }
        if containsAny(lowered, keywords: ["下一首", "下一曲", "next", "切歌", "下一首歌"]) {
            return ParsedIntent(action: .next, extractedQuery: nil)
        }
        if containsAny(lowered, keywords: ["上一首", "上一曲", "previous", "prev", "上一首歌"]) {
            return ParsedIntent(action: .previous, extractedQuery: nil)
        }

        let semanticQuery = normalizedPlayableQuery(
            magicianSemanticPayload(
                from: command,
                actionTokens: ["播放", "放一首", "来一首", "听", "music", "歌曲", "音乐", "暂停", "继续", "下一首", "上一首"],
                extraCommandTokens: ["请", "帮我"]
            )
        )
        if let semanticQuery, !semanticQuery.isEmpty {
            return ParsedIntent(action: .play(query: semanticQuery), extractedQuery: semanticQuery)
        }
        let fallbackQuery = normalizedPlayableQuery(command)
        return ParsedIntent(action: .play(query: fallbackQuery), extractedQuery: fallbackQuery)
    }

    private func normalizedPlayableQuery(_ raw: String?) -> String? {
        guard let raw else {
            return nil
        }
        let trimmed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let compact = compactIntentText(trimmed)
        guard !compact.isEmpty else {
            return nil
        }
        let generic: Set<String> = [
            compactIntentText("播放"),
            compactIntentText("来一首"),
            compactIntentText("放一首"),
            compactIntentText("听"),
            compactIntentText("music"),
            compactIntentText("play"),
            compactIntentText("歌曲"),
            compactIntentText("音乐"),
            compactIntentText("歌")
        ]
        if generic.contains(compact) {
            return nil
        }
        return trimmed
    }

    private struct PlayedTrackEvidence {
        let track: String
        let artist: String?
    }

    private func parseMusicEvidence(_ output: String) -> PlayedTrackEvidence? {
        guard output.hasPrefix("track=") else {
            return nil
        }
        // Example: track=xxx|artist=yyy
        let payload = output.replacingOccurrences(of: "track=", with: "")
        let parts = payload.split(separator: "|").map { String($0) }
        let track = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !track.isEmpty else {
            return nil
        }
        var artist: String?
        for part in parts.dropFirst() {
            if part.hasPrefix("artist=") {
                artist = String(part.dropFirst("artist=".count))
            }
        }
        return PlayedTrackEvidence(track: track, artist: artist)
    }

    private func expectedSongTitle(from query: String) -> String? {
        if let primary = magicianPrimarySongQuery(from: query) {
            let trimmed = primary.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let quoted = firstQuotedSongTitle(in: query) {
            let trimmed = quoted.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let candidates = magicianMusicSearchQueries(from: query)
        return candidates.first
    }

    private func playedTrackTitleMatchesExpected(_ played: String, expectedTitle: String) -> Bool {
        let a = normalizedMusicMatchText(played)
        let b = normalizedMusicMatchText(expectedTitle)
        guard !a.isEmpty, !b.isEmpty else {
            return false
        }
        // Allow minor suffix differences (live/remastered/etc.) while keeping the rule simple.
        return a == b || a.contains(b)
    }

    private func runPlayAction(query: String) async -> MagicianProcessResult {
        let searchQueries = magicianMusicSearchQueries(from: query)
        for item in searchQueries {
            let result = await runOsaScript(
                lines: [
                    "on run argv",
                    "set keywordText to item 1 of argv",
                    // Use Music in-app Search (Apple Music catalog), then play the first tile under Best Results.
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                    "end tell",
                    "delay 0.35",
                    "tell application \"System Events\"",
                    "tell process \"Music\"",
                    "set frontmost to true",
                    "set w to window 1",
                    // Enter Search page if possible (sidebar), otherwise focus search field via Cmd+F.
                    "set didNavigate to false",
                    "try",
                    "set elems0 to entire contents of w",
                    "repeat with e0 in elems0",
                    "try",
                    "if (role of e0) is \"AXButton\" then",
                    "set nm0 to missing value",
                    "try",
                    "set nm0 to name of e0",
                    "end try",
                    "if nm0 is not missing value then",
                    "set nm0Text to nm0 as string",
                    "if (nm0Text is \"搜索\") or (nm0Text is \"Search\") then",
                    "click e0",
                    "set didNavigate to true",
                    "exit repeat",
                    "end if",
                    "end if",
                    "end if",
                    "end if",
                    "end try",
                    "end repeat",
                    "end try",
                    "if didNavigate is false then",
                    "keystroke \"f\" using {command down}",
                    "end if",
                    "delay 0.25",
                    // Find the search text field and type the query.
                    "set searchField to missing value",
                    "repeat with i from 1 to 30",
                    "try",
                    "set elems1 to entire contents of w",
                    "repeat with e1 in elems1",
                    "try",
                    "if (role of e1) is \"AXTextField\" then",
                    "set searchField to e1",
                    "exit repeat",
                    "end if",
                    "end try",
                    "end repeat",
                    "if searchField is not missing value then exit repeat",
                    "end try",
                    "delay 0.1",
                    "end repeat",
                    "if searchField is missing value then return \"ui_script_failed\"",
                    "click searchField",
                    "delay 0.05",
                    "keystroke \"a\" using {command down}",
                    "key code 51",
                    "keystroke keywordText",
                    "key code 36",
                    // Wait for results to render.
                    "delay 1.15",
                    // Pick the first button after the Best Results header (\"最佳结果\").
                    "set targetButton to missing value",
                    "set inBestResults to false",
                    "repeat with attemptIdx from 1 to 30",
                    "set elems to entire contents of w",
                    "repeat with e in elems",
                    "try",
                    "set r to role of e",
                    "if (r is \"AXStaticText\") or (r is \"AXButton\") then",
                    "set nm to missing value",
                    "try",
                    "set nm to name of e",
                    "end try",
                    "if inBestResults is false then",
                    "if nm is not missing value then",
                    "if (nm as string) contains \"最佳结果\" then set inBestResults to true",
                    "end if",
                    "end if",
                    "else",
                    "if r is \"AXButton\" then",
                    "set targetButton to e",
                    "exit repeat",
                    "end if",
                    "end if",
                    "end if",
                    "end if",
                    "end try",
                    "end repeat",
                    "if targetButton is not missing value then exit repeat",
                    "delay 0.20",
                    "end repeat",
                    "if targetButton is missing value then return \"track_not_found\"",
                    // Double-click to start playback.
                    "click targetButton",
                    "delay 0.12",
                    "click targetButton",
                    "end tell",
                    "end tell",
                    "delay 0.8",
                    "tell application \"Music\"",
                ] + magicianEnsureApplicationReadyAppleScriptLines(activate: false) + [
                    "set nowTrack to missing value",
                    "repeat with retryIdx from 1 to 30",
                    "try",
                    "set nowTrack to current track",
                    "exit repeat",
                    "on error",
                    "delay 0.12",
                    "end try",
                    "end repeat",
                    "if nowTrack is not missing value then",
                    "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack)",
                    "end if",
                    "return \"state=play\"",
                    "end tell",
                    "end run"
                ],
                arguments: [item]
            )

            if result.exitCode != 0 {
                return result
            }
            if result.stdout == "ui_script_failed" {
                return MagicianProcessResult(
                    exitCode: 1,
                    stdout: "",
                    stderr: "ui_script_failed"
                )
            }
            if result.stdout.hasPrefix("track=") {
                return result
            }
            if result.stdout == "lookup_error" {
                continue
            }
            if result.stdout == "track_not_found" {
                continue
            }
        }
        return MagicianProcessResult(
            exitCode: 0,
            stdout: "track_not_found",
            stderr: ""
        )
    }

    private func runFallbackPlayAction() async -> MagicianProcessResult {
        await runOsaScript(
            lines: [
                "tell application \"Music\"",
            ] + magicianEnsureApplicationReadyAppleScriptLines() + [
                "play",
                "set nowTrack to missing value",
                "repeat with retryIdx from 1 to 20",
                "try",
                "set nowTrack to current track",
                "exit repeat",
                "on error",
                "delay 0.12",
                "end try",
                "end repeat",
                "if nowTrack is not missing value then",
                "return \"track=\" & (name of nowTrack) & \"|artist=\" & (artist of nowTrack) & \"|fallback=1\"",
                "end if",
                "return \"state=play|fallback=1\"",
                "end tell"
            ],
            arguments: []
        )
    }
}

func summarizedHistoryText(_ text: String, limit: Int = 48) -> String {
    let normalized = text
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
        return "无内容"
    }
    return normalized.count > limit ? "\(normalized.prefix(limit))…" : normalized
}

func magicianMusicSearchQueries(from rawQuery: String) -> [String] {
    let punctuationToTrim = CharacterSet(charactersIn: " \t\r\n。．.!！?？,，、:：;；'\"‘’“”（）()《》〈〉[]【】")
    var value = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    value = value.trimmingCharacters(in: punctuationToTrim)

    let leadingTokens = ["播放", "来一首", "放一首", "听", "music", "play"]
    var lowered = value.lowercased()
    var didTrimLeadingToken = true
    while didTrimLeadingToken, !value.isEmpty {
        didTrimLeadingToken = false
        for token in leadingTokens {
            if lowered.hasPrefix(token) {
                value = String(value.dropFirst(token.count)).trimmingCharacters(in: punctuationToTrim)
                lowered = value.lowercased()
                didTrimLeadingToken = true
                break
            }
        }
    }

    var candidates: [String] = []
    func appendCandidate(_ candidate: String) {
        let cleaned = candidate
            .replacingOccurrences(of: "[《》“”‘’\"']", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: punctuationToTrim)
        guard !cleaned.isEmpty else {
            return
        }
        guard !candidates.contains(cleaned) else {
            return
        }
        candidates.append(cleaned)
    }

    if let quoted = firstQuotedSongTitle(in: value) {
        appendCandidate(quoted)
    }

    if let range = value.range(of: "的"), !range.isEmpty {
        let left = String(value[..<range.lowerBound])
        let right = String(value[range.upperBound...])
        appendCandidate(right)
        appendCandidate(left)
        appendCandidate(value)
    } else {
        appendCandidate(value)
    }

    value
        .components(separatedBy: CharacterSet.whitespaces)
        .forEach { appendCandidate($0) }

    return candidates
}

private func firstQuotedSongTitle(in value: String) -> String? {
    let patterns = [
        "《([^》]+)》",
        "“([^”]+)”",
        "\"([^\"]+)\""
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            continue
        }
        let nsValue = value as NSString
        let range = NSRange(location: 0, length: nsValue.length)
        guard let match = regex.firstMatch(in: value, options: [], range: range), match.numberOfRanges > 1 else {
            continue
        }
        let title = nsValue.substring(with: match.range(at: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
    }
    return nil
}

func magicianMusicEvidenceMatchesQuery(output: String, query: String) -> Bool {
    guard let range = output.range(of: "track=") else {
        return false
    }
    let payload = String(output[range.upperBound...])
    let normalizedPayload = normalizedMusicMatchText(payload)
    guard !normalizedPayload.isEmpty else {
        return false
    }

    if let primarySongQuery = magicianPrimarySongQuery(from: query) {
        let normalizedPrimarySong = normalizedMusicMatchText(primarySongQuery)
        if !normalizedPrimarySong.isEmpty, !normalizedPayload.contains(normalizedPrimarySong) {
            return false
        }
    }

    let candidateQueries = magicianMusicSearchQueries(from: query)
    let verificationCandidates: [String] = {
        if candidateQueries.isEmpty {
            return [query]
        }
        return Array(candidateQueries.prefix(2))
    }()

    for candidate in verificationCandidates {
        let normalizedCandidate = normalizedMusicMatchText(candidate)
        guard !normalizedCandidate.isEmpty else {
            continue
        }
        if normalizedPayload.contains(normalizedCandidate) {
            return true
        }
        let candidateTerms = normalizedMusicCandidateTerms(from: normalizedCandidate)
        if !candidateTerms.isEmpty && candidateTerms.allSatisfy({ normalizedPayload.contains($0) }) {
            return true
        }
    }
    return false
}

private func magicianPrimarySongQuery(from query: String) -> String? {
    if let quoted = firstQuotedSongTitle(in: query) {
        return quoted
    }
    let punctuationToTrim = CharacterSet(charactersIn: " \t\r\n。．.!！?？,，、:：;；'\"‘’“”（）()《》〈〉[]【】")
    let compact = query
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: punctuationToTrim)
    guard !compact.isEmpty else {
        return nil
    }
    if let range = compact.range(of: "的"), !range.isEmpty {
        let right = String(compact[range.upperBound...]).trimmingCharacters(in: punctuationToTrim)
        return right.isEmpty ? nil : right
    }
    return compact
}

private func normalizedMusicCandidateTerms(from value: String) -> [String] {
    value
        .split(separator: "的")
        .map(String.init)
        .filter { $0.count >= 2 }
}

private func normalizedMusicMatchText(_ value: String) -> String {
    value
        .lowercased()
        .replacingOccurrences(of: "[\\p{P}\\p{S}\\s]+", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
