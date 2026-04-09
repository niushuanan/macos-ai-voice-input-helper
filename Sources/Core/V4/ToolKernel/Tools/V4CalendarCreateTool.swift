import EventKit
import Foundation

final class V4CalendarCreateTool: V4Tool, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        let command: String
        let title: String
        let startAt: Date
        let endAt: Date
        let location: String?
        let notes: String?
    }

    struct ResultPayload: Equatable, Sendable {
        let eventIdentifier: String
        let title: String
        let startAt: Date
        let endAt: Date
        let location: String?
        let notes: String?
    }

    typealias CreateHandler = @Sendable (Request) async throws -> ResultPayload

    let spec = V4ToolSpec(
        toolName: "apple.calendar.create",
        displayName: "创建日程",
        summary: "创建本机 Calendar 日程，并返回可核验的事件证据。",
        supportedLanes: V4Lane.allCases,
        inputSchemaVersion: "v1",
        inputSchema: V4ToolInputSchema(
            fields: [
                V4ToolInputField(name: "command", kind: .string, summary: "原始命令"),
                V4ToolInputField(name: "title", kind: .string, isRequired: false, summary: "日程标题"),
                V4ToolInputField(name: "startAt", kind: .string, isRequired: false, summary: "开始时间 ISO8601"),
                V4ToolInputField(name: "endAt", kind: .string, isRequired: false, summary: "结束时间 ISO8601"),
                V4ToolInputField(name: "location", kind: .string, isRequired: false, summary: "地点"),
                V4ToolInputField(name: "notes", kind: .string, isRequired: false, summary: "备注")
            ]
        ),
        requiresPermission: true,
        requiredFeature: .calendar,
        isConcurrencySafe: false,
        mutatesUserData: true,
        supportsStreamingResults: false
    )

    private let createHandler: CreateHandler
    private let errorCatalog = V4ToolErrorCatalog()
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

    init(
        createHandler: @escaping CreateHandler = V4CalendarCreateTool.liveCreateHandler()
    ) {
        self.createHandler = createHandler
    }

    func validateSemanticInput(
        arguments: V4ToolArguments,
        context _: V4ToolExecutionContext
    ) async -> V4ToolSemanticValidationFailure? {
        let command = arguments.string(for: "command")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else {
            return V4ToolSemanticValidationFailure(
                messageForUser: "`command` 不能为空。",
                messageForDebug: "calendar command empty"
            )
        }
        return nil
    }

    func execute(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) async throws -> V4ToolExecutionOutput {
        let command = arguments.string(for: "command") ?? context.request.inputText
        guard let startAt = resolvedStartDate(arguments: arguments, context: context) else {
            throw errorCatalog.semanticValidationFailure(
                toolID: spec.toolID,
                failure: V4ToolSemanticValidationFailure(
                    messageForUser: "未识别到明确时间，请补充具体日期和时间。",
                    messageForDebug: "calendar start date unresolved",
                    recoverAction: "retry_command"
                )
            )
        }

        let title = resolvedTitle(arguments: arguments, context: context, command: command)
        let endAt = resolvedEndDate(arguments: arguments, startAt: startAt)
        let request = Request(
            command: command,
            title: title,
            startAt: startAt,
            endAt: endAt,
            location: arguments.string(for: "location")?.trimmedNilIfEmpty,
            notes: resolvedNotes(arguments: arguments, context: context, command: command)
        )
        let result = try await createHandler(request)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        let summary = "\(result.title)（\(formatter.string(from: result.startAt)) - \(formatter.string(from: result.endAt))）"

        return V4ToolExecutionOutput(
            outputText: "已建日程：\(summary)",
            evidenceSummary: "apple.calendar.create event_id=\(result.eventIdentifier)",
            rawPayload: .object(
                [
                    "eventID": .string(result.eventIdentifier),
                    "title": .string(result.title),
                    "summary": .string(summary),
                    "startAt": .string(iso.string(from: result.startAt)),
                    "endAt": .string(iso.string(from: result.endAt)),
                    "location": result.location.map(V4ToolValue.string) ?? .null,
                    "notes": result.notes.map(V4ToolValue.string) ?? .null
                ]
            )
        )
    }

    private func resolvedTitle(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext,
        command: String
    ) -> String {
        if let explicit = arguments.string(for: "title")?.trimmedNilIfEmpty {
            return String(explicit.prefix(60))
        }

        let preferred = context.request.selectionText?.trimmedNilIfEmpty
            ?? context.latestCompletedOutputText?.trimmedNilIfEmpty
            ?? command.trimmedNilIfEmpty
        guard let preferred else {
            return "新建日程"
        }
        return String(preferred.prefix(20))
    }

    private func resolvedNotes(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext,
        command: String
    ) -> String? {
        if let explicit = arguments.string(for: "notes")?.trimmedNilIfEmpty {
            return explicit
        }
        let candidates = [
            context.request.selectionText,
            context.latestCompletedOutputText,
            command
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmedNilIfEmpty
            if let trimmed, trimmed != resolvedTitle(arguments: arguments, context: context, command: command) {
                return trimmed
            }
        }
        return nil
    }

    private func resolvedStartDate(
        arguments: V4ToolArguments,
        context: V4ToolExecutionContext
    ) -> Date? {
        if
            let value = arguments.string(for: "startAt"),
            let date = parseISO8601(value)
        {
            return date
        }

        let detectorInput = [
            arguments.string(for: "command"),
            context.request.selectionText,
            context.latestCompletedOutputText,
            context.request.inputText
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\n")

        return detectDate(in: detectorInput)
    }

    private func resolvedEndDate(
        arguments: V4ToolArguments,
        startAt: Date
    ) -> Date {
        if
            let value = arguments.string(for: "endAt"),
            let date = parseISO8601(value),
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

    static func liveCreateHandler() -> CreateHandler {
        { request in
            let eventStore = EKEventStore()
            let status = EKEventStore.authorizationStatus(for: .event)
            let granted: Bool
            if status == .fullAccess || status == .writeOnly {
                granted = true
            } else if status == .notDetermined {
                granted = await withCheckedContinuation { continuation in
                    eventStore.requestFullAccessToEvents { isGranted, _ in
                        continuation.resume(returning: isGranted)
                    }
                }
            } else {
                granted = false
            }

            guard granted else {
                throw V4ToolErrorCatalog().permissionDenied(
                    toolID: "apple.calendar.create",
                    decision: V4PermissionDecision(
                        behavior: .deny,
                        traceID: V4TraceID(rawValue: "calendar"),
                        lane: .selectionRewrite,
                        toolName: "apple.calendar.create",
                        reason: "calendar_permission_denied",
                        userMessage: "缺少日历权限，请到系统设置打开后再试。"
                    )
                )
            }

            guard let calendar = eventStore.defaultCalendarForNewEvents else {
                throw V4ToolErrorCatalog().executionFailure(
                    toolID: "apple.calendar.create",
                    userMessage: "当前没有可用日历，请先在系统日历里添加账号。",
                    debugMessage: "defaultCalendarForNewEvents nil",
                    recoverAction: "configure_calendar_account",
                    isRetryable: false
                )
            }

            let event = EKEvent(eventStore: eventStore)
            event.calendar = calendar
            event.title = request.title
            event.location = request.location
            event.startDate = request.startAt
            event.endDate = request.endAt
            event.notes = request.notes

            do {
                try eventStore.save(event, span: .thisEvent)
            } catch {
                throw V4ToolErrorCatalog().executionFailure(
                    toolID: "apple.calendar.create",
                    userMessage: "建日程失败，请稍后再试。",
                    debugMessage: "EKEventStore save failed: \(error.localizedDescription)",
                    recoverAction: "retry_later"
                )
            }

            guard let eventIdentifier = event.eventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !eventIdentifier.isEmpty else {
                throw V4ToolErrorCatalog().missingEvidence(
                    toolID: "apple.calendar.create",
                    requirement: .structured(requiredKeys: ["eventID"]),
                    debugMessage: "event identifier missing after save"
                )
            }

            return ResultPayload(
                eventIdentifier: eventIdentifier,
                title: request.title,
                startAt: request.startAt,
                endAt: request.endAt,
                location: request.location,
                notes: request.notes
            )
        }
    }
}

private extension String {
    var trimmedNilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
