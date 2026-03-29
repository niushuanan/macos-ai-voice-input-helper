import Foundation

struct FeishuResolvedTarget: Equatable {
    let flag: String
    let value: String
    let targetType: String
    let displayName: String
}

private enum FeishuTargetLookupOutcome: Equatable {
    case resolved(FeishuResolvedTarget)
    case ambiguous([FeishuResolvedTarget])
    case missing
}

struct FeishuTargetResolver: MagicianTargetResolver {
    private let processRunner: FeishuCLIProcessRunner

    init(processRunner: FeishuCLIProcessRunner = FeishuCLIProcessRunner(timeoutSeconds: 8, maxOutputCharacters: 6_000)) {
        self.processRunner = processRunner
    }

    func resolveTarget(
        command: String,
        selection: String?,
        focusContext _: FocusedAppContext?
    ) async -> MagicianTargetResolution {
        if let chatID = extractedIdentifier(in: command, prefix: "oc_") {
            return MagicianTargetResolution(
                status: .resolved,
                targetType: "chat",
                targetID: chatID,
                targetName: chatID
            )
        }
        if let userID = extractedIdentifier(in: command, prefix: "ou_") {
            return MagicianTargetResolution(
                status: .resolved,
                targetType: "user",
                targetID: userID,
                targetName: userID
            )
        }

        let candidate = inferredRecipientHint(from: command)
            ?? inferredResourceHint(from: selection)
            ?? inferredResourceHint(from: command)
        guard let candidate, !candidate.isEmpty else {
            return MagicianTargetResolution(status: .missing, prompt: "请补充更具体的目标对象。")
        }

        return MagicianTargetResolution(
            status: .missing,
            targetName: candidate,
            prompt: "还缺少明确的目标对象，请补充更具体的名字、链接或 ID。"
        )
    }

    func resolveIMTarget(
        from spokenCommand: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> MagicianTargetResolution {
        if let chatID = extractedIdentifier(in: spokenCommand, prefix: "oc_") {
            return MagicianTargetResolution(
                status: .resolved,
                targetType: "chat",
                targetID: chatID,
                targetName: chatID
            )
        }
        if let userID = extractedIdentifier(in: spokenCommand, prefix: "ou_") {
            return MagicianTargetResolution(
                status: .resolved,
                targetType: "user",
                targetID: userID,
                targetName: userID
            )
        }

        guard let recipientHint = inferredRecipientHint(from: spokenCommand) else {
            return MagicianTargetResolution(
                status: .missing,
                prompt: "请补充要发送给谁。"
            )
        }

        switch await resolveChat(query: recipientHint, backend: backend) {
        case let .resolved(target):
            return resolvedTargetResolution(from: target)
        case let .ambiguous(targets):
            return ambiguousTargetResolution(
                query: recipientHint,
                targetType: "chat",
                targets: targets,
                promptPrefix: "找到多个群聊"
            )
        case .missing:
            break
        }

        switch await resolveUser(query: recipientHint, backend: backend) {
        case let .resolved(target):
            return resolvedTargetResolution(from: target)
        case let .ambiguous(targets):
            return ambiguousTargetResolution(
                query: recipientHint,
                targetType: "user",
                targets: targets,
                promptPrefix: "找到多个用户"
            )
        case .missing:
            break
        }

        return MagicianTargetResolution(
            status: .missing,
            targetName: recipientHint,
            prompt: "没找到唯一目标，我已经自动换了一种搜索方式再试过一次。请补充更具体的用户名、群名或 open_id。"
        )
    }

    func resolveChatMembersTarget(
        from spokenCommand: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> MagicianTargetResolution {
        if let chatID = extractedIdentifier(in: spokenCommand, prefix: "oc_") {
            return MagicianTargetResolution(
                status: .resolved,
                targetType: "chat",
                targetID: chatID,
                targetName: chatID
            )
        }

        let query = inferredQuery(from: spokenCommand) ?? inferredRecipientHint(from: spokenCommand)
        guard let query, !query.isEmpty else {
            return MagicianTargetResolution(
                status: .missing,
                prompt: "请补充群聊名或 chat_id。"
            )
        }

        switch await resolveChat(query: query, backend: backend) {
        case let .resolved(target):
            return resolvedTargetResolution(from: target)
        case let .ambiguous(targets):
            return ambiguousTargetResolution(
                query: query,
                targetType: "chat",
                targets: targets,
                promptPrefix: "找到多个群聊"
            )
        case .missing:
            break
        }

        return MagicianTargetResolution(
            status: .missing,
            targetName: query,
            prompt: "没找到对应群聊，我已经自动换了一种搜索方式再试过一次。请补充更具体的群名或 chat_id。"
        )
    }

    private func resolveChat(
        query: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> FeishuTargetLookupOutcome {
        await searchTargets(
            query: query,
            backend: backend,
            argumentsBuilder: { candidate in
                ["im", "+chat-search", "--query", candidate, "--format", "json"]
            },
            arrayKeyPath: ["data", "chats"],
            targetBuilder: { object in
                guard let chatID = object["chat_id"] as? String else {
                    return nil
                }
                let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return FeishuResolvedTarget(
                    flag: "--chat-id",
                    value: chatID,
                    targetType: "chat",
                    displayName: (name?.isEmpty == false ? name! : chatID)
                )
            }
        )
    }

    private func resolveUser(
        query: String,
        backend: FeishuCLIBackendDescriptor
    ) async -> FeishuTargetLookupOutcome {
        await searchTargets(
            query: query,
            backend: backend,
            argumentsBuilder: { candidate in
                ["contact", "+search-user", "--query", candidate, "--format", "json"]
            },
            arrayKeyPath: ["data", "users"],
            targetBuilder: { object in
                guard let userID = (object["open_id"] as? String) ?? (object["user_id"] as? String) else {
                    return nil
                }
                let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return FeishuResolvedTarget(
                    flag: "--user-id",
                    value: userID,
                    targetType: "user",
                    displayName: (name?.isEmpty == false ? name! : userID)
                )
            }
        )
    }

    private func searchTargets(
        query: String,
        backend: FeishuCLIBackendDescriptor,
        argumentsBuilder: (String) -> [String],
        arrayKeyPath: [String],
        targetBuilder: ([String: Any]) -> FeishuResolvedTarget?
    ) async -> FeishuTargetLookupOutcome {
        for candidate in searchQueries(for: query) {
            let result = await processRunner.run(
                executablePath: backend.executablePath,
                arguments: argumentsBuilder(candidate)
            )
            guard result.exitCode == 0 else {
                continue
            }

            let targets = deduplicatedTargets(
                parsedObjects(from: result.stdout, arrayKeyPath: arrayKeyPath).compactMap(targetBuilder)
            )
            if targets.count == 1, let first = targets.first {
                return .resolved(first)
            }
            if !targets.isEmpty {
                return .ambiguous(Array(targets.prefix(3)))
            }
        }

        return .missing
    }

    private func deduplicatedTargets(_ targets: [FeishuResolvedTarget]) -> [FeishuResolvedTarget] {
        var seen = Set<String>()
        return targets.filter { seen.insert($0.value).inserted }
    }

    private func searchQueries(for query: String) -> [String] {
        let trimmed = query
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !trimmed.isEmpty else {
            return []
        }

        var candidates = [trimmed]
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        if compact != trimmed {
            candidates.append(compact)
        }
        if let lastSegment = trimmed.split(separator: " ").last, lastSegment != Substring(trimmed) {
            candidates.append(String(lastSegment))
        }
        if let lastComponent = trimmed.split(separator: "的").last, lastComponent != Substring(trimmed) {
            candidates.append(String(lastComponent))
        }

        var seen = Set<String>()
        return candidates.filter { candidate in
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                return false
            }
            return seen.insert(normalized).inserted
        }
    }

    private func resolvedTargetResolution(from target: FeishuResolvedTarget) -> MagicianTargetResolution {
        MagicianTargetResolution(
            status: .resolved,
            targetType: target.targetType,
            targetID: target.value,
            targetName: target.displayName
        )
    }

    private func ambiguousTargetResolution(
        query: String,
        targetType: String,
        targets: [FeishuResolvedTarget],
        promptPrefix: String
    ) -> MagicianTargetResolution {
        let alternatives = targets.map(\.displayName)
        let summary = alternatives.joined(separator: "、")
        let suffix = targetType == "chat" ? "群名或 chat_id" : "用户名或 open_id"
        return MagicianTargetResolution(
            status: .ambiguous,
            targetType: targetType,
            targetName: query,
            prompt: "\(promptPrefix)：\(summary)。请补充更具体的\(suffix)。",
            alternatives: alternatives
        )
    }

    private func inferredRecipientHint(from spokenCommand: String) -> String? {
        let patterns = [
            #"(?:给|发给)\s*(.+?)(?:发消息|消息|说|告诉|，|,|。|$)"#,
            #"(?:把消息发给)\s*(.+?)(?:，|,|。|$)"#,
            #"(?:to)\s*(.+?)(?:message|say|,|$)"#
        ]
        for pattern in patterns {
            if let captured = textMatched(in: spokenCommand, pattern: pattern) {
                let cleaned = captured
                    .replacingOccurrences(of: "飞书的", with: "")
                    .replacingOccurrences(of: "飞书", with: "")
                    .replacingOccurrences(of: "助手", with: " ")
                    .replacingOccurrences(of: "同事", with: " ")
                    .replacingOccurrences(of: "的", with: " ")
                    .replacingOccurrences(of: "lark 的", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "lark", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                guard !cleaned.isEmpty else {
                    continue
                }
                return String(cleaned.prefix(64))
            }
        }
        return nil
    }

    private func inferredQuery(from spokenCommand: String) -> String? {
        let stopWords = [
            "飞书", "feishu", "lark", "查一下", "搜一下", "搜索", "查询", "帮我", "请", "一下", "群成员", "群聊", "消息", "文档", "用户", "任务", "日程"
        ]
        var reduced = spokenCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        for stopWord in stopWords {
            reduced = reduced.replacingOccurrences(of: stopWord, with: "", options: [.caseInsensitive])
        }
        reduced = reduced
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !reduced.isEmpty else {
            return nil
        }
        return String(reduced.prefix(80))
    }

    private func inferredResourceHint(from text: String?) -> String? {
        guard let text else {
            return nil
        }
        let normalized = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !normalized.isEmpty else {
            return nil
        }
        return String(normalized.prefix(80))
    }

    private func textMatched(
        in text: String,
        pattern: String,
        captureGroup: Int = 1
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > captureGroup,
            let matchedRange = Range(match.range(at: captureGroup), in: text)
        else {
            return nil
        }
        return String(text[matchedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractedIdentifier(in text: String, prefix: String) -> String? {
        let escapedPrefix = NSRegularExpression.escapedPattern(for: prefix)
        guard let regex = try? NSRegularExpression(pattern: "\\b\(escapedPrefix)[A-Za-z0-9]+\\b") else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            let matchedRange = Range(match.range, in: text)
        else {
            return nil
        }
        let value = String(text[matchedRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func parsedObjects(from text: String, arrayKeyPath: [String]) -> [[String: Any]] {
        guard
            let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return []
        }

        var current: Any = dictionary
        for key in arrayKeyPath {
            guard let nested = (current as? [String: Any])?[key] else {
                return []
            }
            current = nested
        }

        return current as? [[String: Any]] ?? []
    }
}
