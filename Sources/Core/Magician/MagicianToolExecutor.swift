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
final class MagicianToolExecutor: MagicianToolExecuting {
    private let webSearchAdapter = MagicianWebSearchAdapter()
    private let eventAdapter = MagicianEventAdapter()
    private let noteAdapter = MagicianNoteAdapter()
    private let mailAdapter = MagicianMailDraftAdapter()

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
        case .webSearch:
            return try webSearchAdapter.execute(intent: intent, context: context)
        case .createEvent:
            return try await eventAdapter.execute(intent: intent, context: context)
        case .createNote:
            return try await noteAdapter.execute(intent: intent, context: context)
        case .composeEmailDraft:
            return try mailAdapter.execute(intent: intent, context: context)
        }
    }
}

private struct MagicianWebSearchAdapter {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) throws -> MagicianExecutionResult {
        let query = resolvedQuery(intent: intent, context: context)
        guard !query.isEmpty else {
            throw MagicianError(
                code: .selectionEmpty,
                userMessage: "搜索内容为空，请补一句要搜什么再试。",
                debugMessage: "web search query empty",
                recoverAction: "retry_command"
            )
        }

        guard
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "https://www.google.com/search?q=\(encoded)")
        else {
            throw MagicianError(
                code: .browserUnavailable,
                userMessage: "搜索链接生成失败，请换个指令再试。",
                debugMessage: "failed to build google URL",
                recoverAction: "retry_command"
            )
        }

        let usedFallback: Bool
        if let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: chromeURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
            usedFallback = false
        } else {
            let opened = NSWorkspace.shared.open(url)
            guard opened else {
                throw MagicianError(
                    code: .browserUnavailable,
                    userMessage: "无法打开浏览器，请检查系统默认浏览器设置。",
                    debugMessage: "NSWorkspace open url failed",
                    recoverAction: "check_browser"
                )
            }
            usedFallback = true
        }

        return MagicianExecutionResult(
            intent: .webSearch,
            userMessage: usedFallback ? "已用默认浏览器打开搜索结果。" : "已用 Chrome 打开搜索结果。",
            outputText: url.absoluteString,
            fallbackUsed: usedFallback
        )
    }

    private func resolvedQuery(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let query = intent.params.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !query.isEmpty {
            return query
        }
        let source = intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return source
        }
        return context.command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
        let startAt = resolvedStartDate(intent: intent, context: context)
        let endAt = resolvedEndDate(intent: intent, startAt: startAt)

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.location = location
        event.startDate = startAt
        event.endDate = endAt
        event.notes = """
        来自 PulseType 魔法师

        原文：
        \(context.selectedText.isEmpty ? "（无选中文本）" : context.selectedText)

        指令：
        \(context.command)
        """

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
            fallbackUsed: false
        )
    }

    private func hasCalendarAccess(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess || status == .writeOnly
        }
        return status == .authorized
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
        if
            let title = intent.params.title?.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty
        {
            return String(title.prefix(60))
        }

        let selected = context.selectedText
        if selected.isEmpty {
            let fromCommand = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fromCommand.isEmpty {
                return String(fromCommand.prefix(20))
            }
            return "待办事项"
        }
        return String(selected.prefix(20))
    }

    private func resolvedStartDate(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> Date {
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
        return defaultStartDate()
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

    private func defaultStartDate() -> Date {
        let now = Date()
        let nextHour = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now
        return nextHour
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

        let shortcutName = shortcutSupport.shortcutName
        if shortcutSupport.cliAvailable {
            guard shortcutSupport.hasShortcut(named: shortcutName) else {
                throw MagicianError(
                    code: .shortcutNotFound,
                    userMessage: "没找到快捷指令“\(shortcutName)”。请先在 Shortcuts 创建同名指令。",
                    debugMessage: "shortcut '\(shortcutName)' not found in shortcut list",
                    recoverAction: "create_note_shortcut"
                )
            }

            let result = try await runShortcut(name: shortcutName, inputText: noteBody)
            if result.exitCode == 0 {
                return MagicianExecutionResult(
                    intent: .createNote,
                    userMessage: "已提交到备忘录快捷指令。",
                    outputText: noteBody,
                    fallbackUsed: false
                )
            }

            let detail = result.stderr.isEmpty ? result.stdout : result.stderr
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
                    fallbackUsed: true
                )
            }

            throw MagicianError(
                code: .toolExecutionFailed,
                userMessage: "写入备忘录失败，请稍后再试。",
                debugMessage: detail,
                recoverAction: "retry_later"
            )
        }

        if runShortcutViaURLScheme(name: shortcutName, inputText: noteBody) {
            return MagicianExecutionResult(
                intent: .createNote,
                userMessage: "已通过 Shortcuts URL 触发写入。",
                outputText: noteBody,
                fallbackUsed: true
            )
        }

        throw MagicianError(
            code: .shortcutNotFound,
            userMessage: "系统里没有可用的 shortcuts 命令，请先启用 Shortcuts。",
            debugMessage: "shortcuts executable missing and URL scheme launch failed",
            recoverAction: "open_shortcuts"
        )
    }

    private func resolvedNoteBody(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let body = intent.params.noteBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty {
            return body
        }
        let source = intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return source
        }
        if !context.selectedText.isEmpty {
            return context.selectedText
        }
        return context.command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runShortcut(
        name: String,
        inputText: String
    ) async throws -> ProcessResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magician-note-\(UUID().uuidString)")
            .appendingPathExtension("txt")

        try inputText.write(to: tempURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: MagicianCreateNoteShortcutSupport.shortcutsExecutablePath)
            process.arguments = ["run", name, "--input-path", tempURL.path]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ProcessResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            }

            let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.value
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

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }
}

private struct MagicianMailDraftAdapter {
    func execute(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) throws -> MagicianExecutionResult {
        let recipients = resolvedRecipients(intent: intent)
        let subject = resolvedSubject(intent: intent, context: context)
        let body = resolvedBody(intent: intent, context: context)

        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = recipients
            service.subject = subject
            service.perform(withItems: [body])
            return MagicianExecutionResult(
                intent: .composeEmailDraft,
                userMessage: "已打开邮件草稿窗口。",
                outputText: body,
                fallbackUsed: false
            )
        }

        var components = URLComponents()
        components.scheme = "mailto"
        if !recipients.isEmpty {
            components.path = recipients.joined(separator: ",")
        }
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]

        guard
            let url = components.url,
            NSWorkspace.shared.open(url)
        else {
            throw MagicianError(
                code: .mailUnavailable,
                userMessage: "当前无法打开邮件草稿，请先配置 Mail 账号。",
                debugMessage: "composeEmail service unavailable and mailto open failed",
                recoverAction: "configure_mail_account"
            )
        }

        return MagicianExecutionResult(
            intent: .composeEmailDraft,
            userMessage: "已通过 mailto 打开邮件草稿。",
            outputText: body,
            fallbackUsed: true
        )
    }

    private func resolvedRecipients(intent: MagicianIntent) -> [String] {
        intent.params.mailTo?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    private func resolvedSubject(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let subject = intent.params.mailSubject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !subject.isEmpty {
            return subject
        }
        let selected = context.selectedText
        if selected.isEmpty {
            let source = intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty {
                return String(source.prefix(24))
            }
            let command = context.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                return String(command.prefix(24))
            }
            return "来自 PulseType 的邮件草稿"
        }
        return String(selected.prefix(24))
    }

    private func resolvedBody(
        intent: MagicianIntent,
        context: MagicianExecutionContext
    ) -> String {
        let body = intent.params.mailBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !body.isEmpty {
            return body
        }
        let source = intent.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            return source
        }
        if !context.selectedText.isEmpty {
            return context.selectedText
        }
        return context.command.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
