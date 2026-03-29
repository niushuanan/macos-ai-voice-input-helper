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
                let evidence = await resolvedNoteEvidence(title: noteTitle, body: noteBody) ?? notesResult.stdout
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已写入 Notes。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: false,
                    observation: MagicianAgentObservation(
                        verificationStatus: evidence.isEmpty ? .assumed : .verified,
                        targetSummary: noteTitle,
                        evidenceSummary: evidence.isEmpty ? "Notes 新笔记已创建" : evidence
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
                let evidence = await resolvedNoteEvidence(title: noteTitle, body: noteBody)
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已提交到备忘录快捷指令。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: notesScriptDetail != nil,
                    observation: MagicianAgentObservation(
                        verificationStatus: evidence == nil ? .assumed : .verified,
                        targetSummary: noteTitle,
                        evidenceSummary: evidence ?? "快捷指令已触发"
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
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "CLI 执行失败，已改用 Shortcuts URL 触发写入。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: true
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
            let evidence = await resolvedNoteEvidence(title: noteTitle, body: noteBody)
            return MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已通过 Shortcuts URL 触发写入。",
                outputText: noteBody,
                historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                fallbackUsed: true,
                observation: MagicianAgentObservation(
                    verificationStatus: evidence == nil ? .assumed : .verified,
                    targetSummary: noteTitle,
                    evidenceSummary: evidence ?? "Shortcuts URL 已触发"
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
                "if not running then launch",
                "activate",
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
        return output.isEmpty ? nil : output
    }
}

private struct MagicianMusicAdapter {
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
                    return "已尝试播放：\(query)"
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
        let result = await runAction(action)
        guard result.exitCode == 0 else {
            throw MagicianError(
                code: .musicControlFailed,
                userMessage: "音乐控制失败，请确认 Music 已启动后再试。",
                debugMessage: result.detail,
                recoverAction: "open_music_app"
            )
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = output.isEmpty ? "Music action done" : output
        return MagicianExecutionResult(
            intent: .controlMusic,
            userMessage: action.userMessage,
            outputText: output.isEmpty ? nil : output,
            historyDisplayText: action.userMessage,
            fallbackUsed: false,
            observation: MagicianAgentObservation(
                verificationStatus: .verified,
                evidenceSummary: evidence
            )
        )
    }

    private func resolvedAction(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> Action {
        let command = context.command.lowercased()
        if containsAny(command, keywords: ["暂停", "pause", "停止播放", "停一下"]) {
            return .pause
        }
        if containsAny(command, keywords: ["继续", "恢复", "resume", "继续播放"]) {
            return .resume
        }
        if containsAny(command, keywords: ["下一首", "下一曲", "next", "切歌"]) {
            return .next
        }
        if containsAny(command, keywords: ["上一首", "上一曲", "previous", "prev"]) {
            return .previous
        }

        let query = magicianSemanticPayload(
            from: context.command,
            actionTokens: ["播放", "放一首", "来一首", "听", "music", "歌曲", "音乐", "暂停", "继续", "下一首", "上一首"],
            extraCommandTokens: ["请", "帮我"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let query, !query.isEmpty {
            return .play(query: query)
        }
        let source = intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return .play(query: source)
        }
        return .play(query: nil)
    }

    private func runAction(_ action: Action) async -> MagicianProcessResult {
        switch action {
        case let .play(query):
            if let query, !query.isEmpty {
                return await runOsaScript(
                    lines: [
                        "on run argv",
                        "set keywordText to item 1 of argv",
                        "tell application \"Music\"",
                        "if not running then launch",
                        "activate",
                        "set matchedTracks to (every track of library playlist 1 whose (name contains keywordText) or (artist contains keywordText) or (album contains keywordText))",
                        "if (count of matchedTracks) > 0 then",
                        "set targetTrack to item 1 of matchedTracks",
                        "play targetTrack",
                        "return \"track=\" & (name of targetTrack)",
                        "else",
                        "play",
                        "return \"fallback=play\"",
                        "end if",
                        "end tell",
                        "end run"
                    ],
                    arguments: [query]
                )
            }
            return await runOsaScript(
                lines: [
                    "tell application \"Music\"",
                    "if not running then launch",
                    "activate",
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
                    "if not running then launch",
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
                    "if not running then launch",
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
                    "if not running then launch",
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
                    "if not running then launch",
                    "previous track",
                    "return \"state=previous\"",
                    "end tell"
                ],
                arguments: []
            )
        }
    }

    private func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains { value.contains($0) }
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
