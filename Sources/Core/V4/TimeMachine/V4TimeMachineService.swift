import Foundation

final class V4TimeMachineService: @unchecked Sendable {
    private let store: V4TimeMachineStore
    private let parser: V4TimeParser
    private let scheduler: V4ReminderScheduler

    init(
        store: V4TimeMachineStore,
        parser: V4TimeParser = V4TimeParser(),
        scheduler: V4ReminderScheduler = V4ReminderScheduler()
    ) {
        self.store = store
        self.parser = parser
        self.scheduler = scheduler
    }

    convenience init(
        historyDirectory: URL,
        parser: V4TimeParser = V4TimeParser(),
        scheduler: V4ReminderScheduler = V4ReminderScheduler()
    ) {
        self.init(
            store: V4TimeMachineStore(historyDirectory: historyDirectory),
            parser: parser,
            scheduler: scheduler
        )
    }

    func create(
        rawCommand: String,
        context: V4TimeMachineRequestContext
    ) async throws -> V4TimeMachineCreateResult {
        let normalizedText = normalizedContentText(from: rawCommand, matchedExpression: nil)
        let item = V4TimeItem(
            id: UUID().uuidString,
            sessionID: context.sessionID,
            runID: context.runID,
            traceID: context.traceID,
            lane: context.lane,
            createdAt: context.requestedAt,
            rawCommand: rawCommand,
            normalizedText: normalizedText,
            scheduledAt: nil,
            notificationID: nil,
            tags: makeTags(for: normalizedText, action: "capture"),
            status: .captured
        )

        try await store.save(item)
        let digest = await currentDigest()
        return V4TimeMachineCreateResult(
            item: item,
            parseResult: nil,
            scheduleResult: nil,
            profileDigest: digest
        )
    }

    func remind(
        rawCommand: String,
        context: V4TimeMachineRequestContext
    ) async throws -> V4TimeMachineCreateResult {
        let parseResult = parser.parse(rawCommand, referenceDate: context.requestedAt)
        guard
            parseResult.status == .parsed,
            let scheduledAt = parseResult.scheduledAt
        else {
            throw V4ToolError(
                code: .toolValidationFailed,
                toolID: "time_machine.remind",
                messageForUser: parseResult.hint?.userMessage ?? "提醒时间没解析出来，请换个说法再试。",
                messageForDebug: parseResult.hint?.debugMessage ?? parseResult.resolutionSummary,
                recoverAction: "retry_command",
                isRetryable: false
            )
        }

        let normalizedText = parseResult.normalizedText
        let baseItem = V4TimeItem(
            id: UUID().uuidString,
            sessionID: context.sessionID,
            runID: context.runID,
            traceID: context.traceID,
            lane: context.lane,
            createdAt: context.requestedAt,
            rawCommand: rawCommand,
            normalizedText: normalizedText,
            scheduledAt: scheduledAt,
            notificationID: nil,
            tags: makeTags(for: normalizedText, action: "remind"),
            status: .captured
        )

        let scheduleResult = await scheduler.schedule(for: baseItem)
        let storedItem = V4TimeItem(
            id: baseItem.id,
            sessionID: baseItem.sessionID,
            runID: baseItem.runID,
            traceID: baseItem.traceID,
            lane: baseItem.lane,
            createdAt: baseItem.createdAt,
            rawCommand: baseItem.rawCommand,
            normalizedText: baseItem.normalizedText,
            scheduledAt: baseItem.scheduledAt,
            notificationID: scheduleResult.notificationID,
            tags: baseItem.tags,
            status: scheduleResult.status == .scheduled ? .scheduled : .scheduleFailed
        )

        try await store.save(storedItem)
        let digest = await currentDigest()
        return V4TimeMachineCreateResult(
            item: storedItem,
            parseResult: parseResult,
            scheduleResult: scheduleResult,
            profileDigest: digest
        )
    }

    func currentDigest() async -> V4UserProfileDigest {
        let items = await store.allItems()
        return V4UserProfileDigestBuilder.make(from: items)
    }

    private func normalizedContentText(
        from rawCommand: String,
        matchedExpression: String?
    ) -> String {
        var text = rawCommand
        if let matchedExpression, !matchedExpression.isEmpty {
            text = text.replacingOccurrences(of: matchedExpression, with: " ")
        }

        let patterns = [
            #"提醒我"#,
            #"提醒一下"#,
            #"提醒"#,
            #"记一下"#,
            #"记一条"#,
            #"记下来"#,
            #"记住"#,
            #"灵感"#,
            #"想法"#,
            #"待办"#,
            #"todo"#,
            #"稍后"#,
            #"之后"#,
            #"帮我"#,
            #"请"#,
            #"："#,
            #":"#
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        return normalized.isEmpty ? rawCommand.trimmingCharacters(in: .whitespacesAndNewlines) : normalized
    }

    private func makeTags(for normalizedText: String, action: String) -> [String] {
        var tags = ["action:\(action)"]
        tags.append(contentsOf: extractedTopicTags(from: normalizedText))
        return deduplicated(tags)
    }

    private func extractedTopicTags(from normalizedText: String) -> [String] {
        let stripped = normalizedText
            .replacingOccurrences(of: #"[，,。；;：:\(\)\[\]【】“”"']"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !stripped.isEmpty else {
            return []
        }

        var topics: [String] = []
        let englishWords = stripped
            .split(separator: " ")
            .map(String.init)
            .filter { $0.range(of: #"[A-Za-z]{3,}"#, options: .regularExpression) != nil }
        topics.append(contentsOf: englishWords.prefix(2))

        let chineseMatches = stripped.matches(
            pattern: #"[\p{Han}]{2,6}"#
        )
        let stopwords: Set<String> = [
            "提醒我", "提醒一下", "提醒", "记一下", "记一条", "记下来", "记住", "稍后", "之后"
        ]
        for match in chineseMatches where !stopwords.contains(match) {
            topics.append(match)
        }

        return deduplicated(Array(topics.prefix(3)))
    }

    private func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                result.append(value)
            }
        }
        return result
    }
}

private extension String {
    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { match in
            guard let range = Range(match.range, in: self) else {
                return nil
            }
            return String(self[range])
        }
    }
}
