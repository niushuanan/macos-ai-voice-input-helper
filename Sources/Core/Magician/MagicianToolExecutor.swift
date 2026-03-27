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
    private let mailAdapter: any MagicianMailExecuting

    init(
        providerSettingsStore: ProviderSettingsStore? = nil,
        mailAddressBookStore: MailAddressBookStore? = nil,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        mailAdapter: (any MagicianMailExecuting)? = nil
    ) {
        let resolvedMailAddressBookStore = mailAddressBookStore ?? MailAddressBookStore()
        self.mailAdapter = mailAdapter ?? MagicianMailAdapter(
            addressBookStore: resolvedMailAddressBookStore,
            providerSettingsStore: providerSettingsStore,
            generationProvider: generationProvider
        )
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

func compactIntentText(_ value: String) -> String {
    let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
    return value.lowercased()
        .components(separatedBy: separators)
        .joined()
}

func isLikelyInstructionPhrase(
    _ candidate: String,
    command: String,
    actionTokens: [String]
) -> Bool {
    let compactCandidate = compactIntentText(candidate)
    guard !compactCandidate.isEmpty else {
        return true
    }
    if compactCandidate == compactIntentText(command) {
        return true
    }

    var reduced = compactCandidate
    let baseTokens = [
        "帮我", "请", "一下", "帮忙", "把", "给我", "这段", "这个", "内容", "文字", "文本"
    ] + actionTokens
    for token in baseTokens {
        let compactToken = compactIntentText(token)
        guard !compactToken.isEmpty else {
            continue
        }
        reduced = reduced.replacingOccurrences(of: compactToken, with: "")
    }
    return reduced.isEmpty || reduced.count <= 2
}

func magicianNormalizedText(_ value: String?) -> String? {
    guard let value else {
        return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func magicianSemanticPayload(
    from command: String,
    actionTokens: [String],
    extraCommandTokens: [String] = [],
    stripRecipientDirectives: Bool = false
) -> String? {
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedCommand.isEmpty else {
        return nil
    }

    var candidate = trimmedCommand
    if stripRecipientDirectives {
        candidate = removingRecipientDirectiveSegments(in: candidate)
    }
    candidate = removingCommandSkeleton(
        in: candidate,
        actionTokens: actionTokens,
        extraCommandTokens: extraCommandTokens
    )
    candidate = candidate
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: magicianCommandTrimCharacterSet)
    candidate = trimmingLeadingActionVerb(
        in: candidate,
        actionTokens: actionTokens + extraCommandTokens
    )

    guard !candidate.isEmpty else {
        return nil
    }
    if isLikelyInstructionPhrase(
        candidate,
        command: trimmedCommand,
        actionTokens: actionTokens + extraCommandTokens
    ) {
        return nil
    }
    return candidate
}

func magicianResolvedPayload(
    selectedText: String,
    sourceText: String?,
    command: String,
    actionTokens: [String],
    extraCommandTokens: [String] = [],
    stripRecipientDirectives: Bool = false
) -> String? {
    if let selected = magicianNormalizedText(selectedText), !selected.isEmpty {
        return selected
    }

    let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    if
        let source = magicianNormalizedText(sourceText),
        !isLikelyInstructionPhrase(
            source,
            command: normalizedCommand,
            actionTokens: actionTokens + extraCommandTokens
        )
    {
        return source
    }

    return magicianSemanticPayload(
        from: normalizedCommand,
        actionTokens: actionTokens,
        extraCommandTokens: extraCommandTokens,
        stripRecipientDirectives: stripRecipientDirectives
    )
}

private func removingRecipientDirectiveSegments(in value: String) -> String {
    var output = value
    let patterns = [
        #"(?i)(^|[，,。；;、\s])(?:发给|寄给|写给|to)\s*[^，,。；;、\n]+"#,
        #"(?i)(^|[，,。；;、\s])给\s*[^，,。；;、\n]+(?:发邮件|写邮件|邮件|mail|email)"#
    ]
    for pattern in patterns {
        output = output.replacingOccurrences(
            of: pattern,
            with: " ",
            options: .regularExpression
        )
    }
    return output
}

private func trimmingLeadingActionVerb(
    in value: String,
    actionTokens: [String]
) -> String {
    var output = value.trimmingCharacters(in: magicianCommandTrimCharacterSet)
    guard let first = output.first else {
        return output
    }

    let verb = String(first)
    let leadingVerbs: Set<String> = ["记", "写", "发", "建", "创", "改", "翻", "整", "安", "提"]
    guard leadingVerbs.contains(verb) else {
        return output
    }
    guard actionTokens.contains(where: { $0.hasPrefix(verb) }) else {
        return output
    }

    output = String(output.dropFirst())
        .trimmingCharacters(in: magicianCommandTrimCharacterSet)
    return output
}

private func removingCommandSkeleton(
    in value: String,
    actionTokens: [String],
    extraCommandTokens: [String]
) -> String {
    var output = value
    let tokens = Set(
        [
            "请帮我", "请你", "帮我", "帮忙", "麻烦", "拜托",
            "帮我把", "请把", "请将", "把", "将",
            "一下", "一下子", "整理一下", "整理成",
            "写一封", "写封", "草拟", "草稿"
        ] + actionTokens + extraCommandTokens
    )

    for token in tokens.sorted(by: { $0.count > $1.count }) {
        guard !token.isEmpty else {
            continue
        }
        output = output.replacingOccurrences(
            of: token,
            with: "",
            options: [.caseInsensitive]
        )
    }
    output = output.replacingOccurrences(
        of: #"(?:^|[，,。；;、\s])(?:请|帮我|麻烦|拜托)+(?=[，,。；;、\s]|$)"#,
        with: " ",
        options: .regularExpression
    )
    return output
}

private let magicianCommandTrimCharacterSet: CharacterSet = {
    CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
        .union(CharacterSet(charactersIn: "，。；：、（）【】《》“”‘’「」『』—-"))
}()

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
            fallbackUsed: false
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
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已写入 Notes。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: false
                )
            }
            notesScriptDetail = notesResult.detail
        }

        let shortcutName = shortcutSupport.shortcutName
        let shortcutExists = shortcutSupport.hasShortcut(named: shortcutName)
        if shortcutSupport.cliAvailable, shortcutExists {
            let result = try await runShortcut(name: shortcutName, inputText: noteBody)
            if result.exitCode == 0 {
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已提交到备忘录快捷指令。",
                    outputText: noteBody,
                    historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                    fallbackUsed: notesScriptDetail != nil
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
            return MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已通过 Shortcuts URL 触发写入。",
                outputText: noteBody,
                historyDisplayText: "已写入备忘录：\(summarizedHistoryText(noteBody))",
                fallbackUsed: true
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
                "end tell",
                "end run"
            ],
            arguments: [title, body]
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

struct MagicianWorkflowStepExecutionRequest {
    let step: MagicianWorkflowStep
    let index: Int
    let stepExecutionKey: String
    let context: MagicianWorkflowExecutionContext
    let latestOutputText: String?
}

struct MagicianWorkflowStepExecutionResponse {
    let userMessage: String
    let outputText: String?
    let historyDisplayText: String?
    let fallbackUsed: Bool
}

@MainActor
final class MagicianWorkflowExecutor {
    typealias StepExecutionHandler = (MagicianWorkflowStepExecutionRequest) async throws -> MagicianWorkflowStepExecutionResponse

    func execute(
        plan: MagicianWorkflowPlan,
        context: MagicianWorkflowExecutionContext,
        stepHandler: StepExecutionHandler
    ) async throws -> MagicianWorkflowExecutionResult {
        var stepResults: [MagicianWorkflowStepResult] = []
        var latestOutputText: String?
        var executedKeys = Set<String>()

        for (index, step) in plan.steps.enumerated() {
            let stepExecutionKey = "\(context.traceID):\(index):\(step.stepID):\(step.feature.rawValue)"
            guard executedKeys.insert(stepExecutionKey).inserted else {
                continue
            }
            let response = try await executeWithRetry(
                step: step,
                index: index,
                stepExecutionKey: stepExecutionKey,
                context: context,
                latestOutputText: latestOutputText,
                handler: stepHandler
            )
            let result = MagicianWorkflowStepResult(
                step: step,
                userMessage: response.userMessage,
                outputText: response.outputText,
                historyDisplayText: response.historyDisplayText,
                fallbackUsed: response.fallbackUsed
            )
            stepResults.append(result)
            if
                let output = response.outputText?.trimmingCharacters(in: .whitespacesAndNewlines),
                !output.isEmpty
            {
                latestOutputText = output
            }
        }

        let finalStatus = stepResults.last?.userMessage ?? "流程已完成。"
        return MagicianWorkflowExecutionResult(
            stepResults: stepResults,
            finalStatusMessage: finalStatus,
            finalOutputText: latestOutputText
        )
    }

    private func executeWithRetry(
        step: MagicianWorkflowStep,
        index: Int,
        stepExecutionKey: String,
        context: MagicianWorkflowExecutionContext,
        latestOutputText: String?,
        handler: StepExecutionHandler
    ) async throws -> MagicianWorkflowStepExecutionResponse {
        let policy = step.retryPolicy ?? .default
        let maxAttempts = max(1, policy.maxAttempts)

        for attempt in 1...maxAttempts {
            do {
                return try await handler(
                    MagicianWorkflowStepExecutionRequest(
                        step: step,
                        index: index,
                        stepExecutionKey: stepExecutionKey,
                        context: context,
                        latestOutputText: latestOutputText
                    )
                )
            } catch {
                guard attempt < maxAttempts, isTransient(error) else {
                    throw error
                }
                let delayMs = attempt - 1 < policy.backoffMilliseconds.count
                    ? policy.backoffMilliseconds[attempt - 1]
                    : policy.backoffMilliseconds.last ?? 0
                if delayMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
            }
        }

        throw MagicianError(
            code: .toolExecutionFailed,
            userMessage: "步骤执行失败，请稍后重试。",
            debugMessage: "workflow retry exhausted",
            recoverAction: "retry_command"
        )
    }

    private func isTransient(_ error: Error) -> Bool {
        if let magicianError = error as? MagicianError {
            switch magicianError.code {
            case .toolExecutionFailed, .mailAppleScriptFailed, .browserUnavailable:
                return true
            default:
                return false
            }
        }

        if let rewriteError = error as? RewriteProviderError {
            if case .generationFailed = rewriteError {
                return true
            }
            return false
        }

        if let outputError = error as? TextOutputError {
            switch outputError {
            case .accessibilityPathFailed, .fallbackFailed, .pasteShortcutInjectionFailed:
                return true
            default:
                return false
            }
        }

        return false
    }
}
