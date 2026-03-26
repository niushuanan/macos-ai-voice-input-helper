import Foundation

@MainActor
protocol MagicianIntentRouting {
    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent
}

private func containsUnsupportedSearchIntent(_ command: String) -> Bool {
    let lowered = command.lowercased()
    return ["搜索", "搜一下", "搜一搜", "查一下", "查一查", "google", "search"].contains {
        lowered.contains($0)
    }
}

private func unsupportedSearchIntentError() -> MagicianError {
    MagicianError(
        code: .intentParseFailed,
        userMessage: "快速搜索已下线，请改用别的魔术先生能力。",
        debugMessage: "web_search removed from magician",
        recoverAction: nil
    )
}

struct MagicianPromptProfile {
    static let commonSystemPrompt = """
    You are the dedicated LLM orchestration layer for PulseType's Magician lane on macOS.

    Hard rules:
    1) The spoken command is the highest-priority instruction.
    2) Selected text and the spoken command are separate channels. Never mix or merge them.
    3) When selected text is non-empty, treat it as the primary content payload.
    4) Never put generic command phrases into titles, subjects, bodies, or notes.
    5) Never invent missing facts, dates, times, recipients, or locations.
    6) Follow the requested output format exactly.
    """
}

struct MagicianIntentClassification: Codable, Equatable {
    let intent: MagicianFeatureID
    let confidence: Double
}

struct MagicianIntentExtractionPayload: Codable, Equatable {
    let sourceText: String?
    let params: MagicianIntentParams
}

struct MagicianTextTransformLabelResolver {
    static func label(for instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "按指令处理"
        }
        if trimmed.count <= 14 {
            return trimmed
        }
        return "\(trimmed.prefix(14))..."
    }
}

struct MagicianTextTransformPromptBuilder {
    func build(
        intent _: RewriteIntent,
        request: SelectionRewriteRequest
    ) -> RewritePromptTemplate {
        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a precise text transformation engine for PulseType Magician.
        The spoken command is the highest-priority instruction and must be followed exactly.
        Return only the final transformed text with no explanations, notes, or quotation marks.
        Transform only the selected text.
        Preserve key facts, names, numbers, and intent unless the spoken command explicitly asks you to change them.
        Do not summarize, reorder, structure into bullet points, sort, shorten, polish, or translate by default.
        Only do those things when the spoken command explicitly asks for them.
        If the spoken command asks for a style transformation, rewrite fully in that style.
        """

        let userPrompt = """
        Spoken command (authoritative):
        <<<COMMAND
        \(request.spokenInstruction)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(request.selectedText)
        TEXT>>>
        """

        return RewritePromptTemplate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }
}

struct MagicianIntentClassifierPromptBuilder {
    func build(
        enabledFeatures: Set<MagicianFeatureID>,
        command: String,
        selection: String
    ) -> RewritePromptTemplate {
        let allowedIntents = MagicianFeatureID.allCases
            .filter { enabledFeatures.contains($0) }
            .map(\.rawValue)
            .joined(separator: ", ")

        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are an intent classifier for PulseType Magician.
        Return JSON only. Do not add markdown fences.

        Allowed intent values:
        \(allowedIntents)

        Output JSON schema:
        {
          "intent": "text_transform | create_event | create_note | compose_email_draft",
          "confidence": 0.0
        }

        Rules:
        1) Pick exactly one allowed intent.
        2) Confidence must be a number between 0 and 1.
        3) Use the spoken command to identify the action category.
        4) Use selected text only as supporting context for classification.
        """

        let userPrompt = """
        Spoken command:
        <<<COMMAND
        \(command)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(selection.isEmpty ? "(empty)" : selection)
        TEXT>>>
        """

        return RewritePromptTemplate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }
}

protocol MagicianIntentExtractionPromptBuilding {
    func build(command: String, selection: String) -> RewritePromptTemplate
}

private struct MagicianMailComposerPayload: Codable, Equatable {
    let mailSubject: String?
    let mailBody: String?
}

struct MagicianEventPromptBuilder: MagicianIntentExtractionPromptBuilding {
    func build(command: String, selection: String) -> RewritePromptTemplate {
        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a calendar event extractor for PulseType Magician.
        Return JSON only. Do not add markdown fences.

        Output JSON schema:
        {
          "sourceText": "string",
          "params": {
            "title": "string",
            "startAt": "ISO8601",
            "endAt": "ISO8601",
            "location": "string",
            "notes": "string"
          }
        }

        Rules:
        1) When selected text is non-empty, use it as the primary content source.
        2) The spoken command may only supplement date, time, location, or tone.
        3) Never place generic command phrases into title or notes.
        4) Do not invent startAt or endAt. Leave them empty if not explicit.
        5) Title should describe the real event, not the command.
        """

        let userPrompt = """
        Spoken command:
        <<<COMMAND
        \(command)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(selection.isEmpty ? "(empty)" : selection)
        TEXT>>>
        """

        return RewritePromptTemplate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}

struct MagicianNotePromptBuilder: MagicianIntentExtractionPromptBuilding {
    func build(command: String, selection: String) -> RewritePromptTemplate {
        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a note capture extractor for PulseType Magician.
        Return JSON only. Do not add markdown fences.

        Output JSON schema:
        {
          "sourceText": "string",
          "params": {
            "title": "string",
            "noteBody": "string"
          }
        }

        Rules:
        1) When selected text is non-empty, noteBody should come from selected text.
        2) The spoken command may only supplement title or intent.
        3) Never place generic command phrases into title or noteBody.
        4) Keep sourceText aligned with the real content payload.
        """

        let userPrompt = """
        Spoken command:
        <<<COMMAND
        \(command)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(selection.isEmpty ? "(empty)" : selection)
        TEXT>>>
        """

        return RewritePromptTemplate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}

struct MagicianEmailPromptBuilder: MagicianIntentExtractionPromptBuilding {
    func build(command: String, selection: String) -> RewritePromptTemplate {
        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a mail intent extractor for PulseType Magician.
        Return JSON only. Do not add markdown fences.

        Output JSON schema:
        {
          "sourceText": "string",
          "params": {
            "mailTo": ["a@example.com"],
            "mailRecipientHints": ["小庄", "1379804870", "谷歌邮箱"],
            "mailDeliveryMode": "draft_only | auto_send_if_resolved"
          }
        }

        Rules:
        1) Use the spoken command to identify recipients, recipient hints, and whether the user wants a draft only or wants the message sent immediately when recipients are resolved.
        2) Put only complete, valid email addresses into mailTo.
        3) Put nicknames, number fragments, provider hints, and other incomplete recipient clues into mailRecipientHints.
        4) mailDeliveryMode must be draft_only or auto_send_if_resolved.
        5) Never invent email addresses in this step.
        6) Keep sourceText aligned with the real content payload, not with generic command phrases.
        """

        let userPrompt = """
        Spoken command:
        <<<COMMAND
        \(command)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(selection.isEmpty ? "(empty)" : selection)
        TEXT>>>
        """

        return RewritePromptTemplate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}

struct MagicianMailComposerPromptBuilder: MagicianIntentExtractionPromptBuilding {
    func build(command: String, selection: String) -> RewritePromptTemplate {
        let systemPrompt = """
        \(MagicianPromptProfile.commonSystemPrompt)

        You are a mail composer for PulseType Magician.
        Return JSON only. Do not add markdown fences.

        Output JSON schema:
        {
          "mailSubject": "string",
          "mailBody": "string"
        }

        Rules:
        1) When selected text is non-empty, treat it as the primary source material for the email body.
        2) The spoken command mainly controls recipients, tone, and whether this should be sent now or left as a draft.
        3) Never place generic command phrases into mailSubject or mailBody.
        4) mailSubject should be concise and useful.
        5) mailBody should be directly sendable as an email draft.
        """

        let userPrompt = """
        Spoken command:
        <<<COMMAND
        \(command)
        COMMAND>>>

        Selected text:
        <<<TEXT
        \(selection.isEmpty ? "(empty)" : selection)
        TEXT>>>
        """

        return RewritePromptTemplate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }
}

struct MagicianIntentSchemaValidator {
    func validate(
        _ intent: MagicianIntent,
        enabledFeatures: Set<MagicianFeatureID>,
        command: String? = nil,
        selection: String? = nil
    ) throws -> MagicianIntent {
        guard enabledFeatures.contains(intent.intent) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "这条指令对应的能力还没开启，请先到魔术先生页面打开开关。",
                debugMessage: "intent=\(intent.intent.rawValue) not enabled",
                recoverAction: "open_magician_settings"
            )
        }

        guard intent.confidence.isFinite else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没听清这条命令的意图，请换个说法再试。",
                debugMessage: "confidence is not finite",
                recoverAction: "retry_command"
            )
        }

        let confidence = max(0, min(1, intent.confidence))
        var params = intent.params
        params.targetLanguage = normalized(params.targetLanguage)
        params.tone = normalized(params.tone)
        params.title = normalized(params.title)
        params.startAt = normalizeISO8601String(params.startAt)
        params.endAt = normalizeISO8601String(params.endAt)
        params.location = normalized(params.location)
        params.notes = normalized(params.notes)
        params.noteBody = normalized(params.noteBody)
        params.mailRecipientHints = normalizeRecipientHints(params.mailRecipientHints)
        params.mailSubject = normalized(params.mailSubject)
        params.mailBody = normalized(params.mailBody)
        params.mailTo = normalizeEmails(params.mailTo)

        let normalizedCommand = normalized(command) ?? ""
        let normalizedSelection = normalized(selection) ?? ""
        let hasSelection = !normalizedSelection.isEmpty
        var sourceText = normalized(intent.sourceText) ?? ""

        switch intent.intent {
        case .textTransform:
            if hasSelection {
                sourceText = normalizedSelection
            }
            guard !sourceText.isEmpty else {
                throw MagicianError(
                    code: .selectionEmpty,
                    userMessage: "文字处理需要先选中内容再说指令。",
                    debugMessage: "text_transform sourceText empty",
                    recoverAction: "select_text_first"
                )
            }
        case .createEvent:
            if hasSelection {
                sourceText = normalizedSelection
            }
            if (params.title ?? "").isEmpty {
                let fallbackSource = hasSelection
                    ? normalizedSelection
                    : (sourceText.isEmpty ? normalizedCommand : sourceText)
                let title = fallbackSource.trimmingCharacters(in: .whitespacesAndNewlines)
                params.title = title.isEmpty ? nil : String(title.prefix(60))
            } else if hasSelection, shouldReplaceWithSelectionContent(
                params.title,
                command: normalizedCommand,
                actionTokens: ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event"]
            ) {
                params.title = String(normalizedSelection.prefix(60))
            }
            if hasSelection, (params.notes ?? "").isEmpty {
                params.notes = normalizedSelection
            }
            if (params.startAt ?? "").isEmpty {
                let detectorSource = [sourceText, normalizedCommand]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                params.startAt = detectedEventStartAt(from: detectorSource)
            }
            guard (params.startAt ?? "").isEmpty == false else {
                throw MagicianError(
                    code: .intentParseFailed,
                    userMessage: "未识别到明确时间，请补充具体日期和时间。",
                    debugMessage: "create_event missing startAt",
                    recoverAction: "retry_command"
                )
            }
        case .createNote:
            if hasSelection {
                sourceText = normalizedSelection
                params.noteBody = normalizedSelection
                break
            }
            if (params.noteBody ?? "").isEmpty {
                let fallback = sourceText.isEmpty ? normalizedCommand : sourceText
                params.noteBody = fallback.isEmpty ? nil : fallback
            }
        case .composeEmailDraft:
            params.mailDeliveryMode = params.mailDeliveryMode ?? resolvedMailDeliveryMode(from: normalizedCommand)
            params.mailRecipientHints = mergeRecipientHints(
                params.mailRecipientHints,
                fallbackHints: detectedRecipientHints(
                    from: normalizedCommand,
                    excludingEmails: params.mailTo ?? []
                )
            )
            if hasSelection {
                sourceText = normalizedSelection
                params.mailBody = sanitizedMailBody(
                    candidate: params.mailBody,
                    command: normalizedCommand,
                    selection: normalizedSelection,
                    sourceText: normalizedSelection
                )
                params.mailSubject = sanitizedMailSubject(
                    candidate: params.mailSubject,
                    command: normalizedCommand,
                    selection: normalizedSelection,
                    sourceText: normalizedSelection
                )
                if (params.mailSubject ?? "").isEmpty || shouldReplaceWithSelectionContent(
                    params.mailSubject,
                    command: normalizedCommand,
                    actionTokens: ["邮件", "草稿", "mail", "email", "主题", "subject"]
                ) {
                    params.mailSubject = defaultMailSubject(from: normalizedSelection)
                }
                break
            }
            let fallbackSource = sourceText.isEmpty ? normalizedCommand : sourceText
            params.mailBody = sanitizedMailBody(
                candidate: params.mailBody,
                command: normalizedCommand,
                selection: normalizedSelection,
                sourceText: fallbackSource
            )
            params.mailSubject = sanitizedMailSubject(
                candidate: params.mailSubject,
                command: normalizedCommand,
                selection: normalizedSelection,
                sourceText: fallbackSource
            )
        }

        return MagicianIntent(
            intent: intent.intent,
            confidence: confidence,
            sourceText: sourceText,
            params: params
        )
    }

    private func shouldReplaceWithSelectionContent(
        _ value: String?,
        command: String,
        actionTokens: [String]
    ) -> Bool {
        guard let value = normalized(value) else {
            return true
        }
        return isLikelyInstructionPhrase(
            value,
            command: command,
            actionTokens: actionTokens
        )
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalizeISO8601String(_ value: String?) -> String? {
        guard let text = normalized(value) else {
            return nil
        }
        if Self.iso8601WithFractional.date(from: text) != nil || Self.iso8601.date(from: text) != nil {
            return text
        }
        return nil
    }

    private func isLikelyInstructionPhrase(
        _ text: String,
        command: String,
        actionTokens: [String]
    ) -> Bool {
        let compactText = compactIntentText(text)
        guard !compactText.isEmpty else {
            return true
        }
        if compactText == compactIntentText(command) {
            return true
        }

        var reduced = compactText
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

    private func compactIntentText(_ value: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return value.lowercased()
            .components(separatedBy: separators)
            .joined()
    }

    private func normalizeEmails(_ values: [String]?) -> [String]? {
        guard let values else {
            return nil
        }
        let filtered = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.emailRegex.firstMatch(in: $0, options: [], range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        return filtered.isEmpty ? nil : filtered
    }

    private func normalizeRecipientHints(_ values: [String]?) -> [String]? {
        guard let values else {
            return nil
        }
        var deduped: [String] = []
        var seen = Set<String>()
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = MailAddressBookStore.normalizedLookupKey(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else {
                continue
            }
            deduped.append(trimmed)
        }
        return deduped.isEmpty ? nil : deduped
    }

    private func mergeRecipientHints(
        _ existing: [String]?,
        fallbackHints: [String]?
    ) -> [String]? {
        normalizeRecipientHints((existing ?? []) + (fallbackHints ?? []))
    }

    private func resolvedMailDeliveryMode(from command: String) -> MagicianMailDeliveryMode {
        let lowered = command.lowercased()
        if ["草拟", "草稿", "整理成邮件", "整理一下邮件", "帮我写邮件", "draft"].contains(where: { lowered.contains($0) }) {
            return .draftOnly
        }
        if ["发送", "发给", "发出", "寄给", "send"].contains(where: { lowered.contains($0) }) {
            return .autoSendIfResolved
        }
        return .draftOnly
    }

    private func detectedRecipientHints(
        from command: String,
        excludingEmails emails: [String]
    ) -> [String]? {
        let normalizedEmailKeys = Set(emails.map(MailAddressBookStore.normalizedLookupKey))
        let markers = ["发给", "给", "寄给", "写给", "to"]
        var candidates: [String] = []
        for marker in markers {
            guard let range = command.range(of: marker, options: [.caseInsensitive]) else {
                continue
            }
            var value = String(command[range.upperBound...])
            if let stopRange = value.range(of: "主题", options: [.caseInsensitive]) {
                value = String(value[..<stopRange.lowerBound])
            }
            value = value
                .replacingOccurrences(of: "发邮件", with: "")
                .replacingOccurrences(of: "写邮件", with: "")
                .replacingOccurrences(of: "邮件", with: "")
                .replacingOccurrences(of: "邮箱", with: "邮箱")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                continue
            }
            candidates.append(value)
        }

        let normalized = normalizeRecipientHints(candidates) ?? []
        let filtered = normalized.filter {
            !normalizedEmailKeys.contains(MailAddressBookStore.normalizedLookupKey($0))
        }
        return filtered.isEmpty ? nil : filtered
    }

    private func sanitizedMailSubject(
        candidate: String?,
        command: String,
        selection: String,
        sourceText: String
    ) -> String? {
        if
            let candidate,
            !candidate.isEmpty,
            !shouldReplaceWithSelectionContent(
                candidate,
                command: command,
                actionTokens: ["邮件", "草稿", "mail", "email", "主题", "subject", "发给", "发送"]
            )
        {
            return String(candidate.prefix(48))
        }

        let fallback = [sourceText, selection, command]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let fallback else {
            return nil
        }
        return defaultMailSubject(from: fallback)
    }

    private func defaultMailSubject(from text: String) -> String {
        String(
            text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(48)
        )
    }

    private func sanitizedMailBody(
        candidate: String?,
        command: String,
        selection: String,
        sourceText: String
    ) -> String? {
        if
            let candidate,
            !candidate.isEmpty,
            !shouldReplaceWithSelectionContent(
                candidate,
                command: command,
                actionTokens: ["邮件", "草稿", "mail", "email", "发邮件", "写邮件", "发给", "发送"]
            )
        {
            return candidate
        }

        let fallback = !sourceText.isEmpty ? sourceText : (!selection.isEmpty ? selection : command)
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func detectedEventStartAt(from text: String) -> String? {
        let normalizedText = normalized(text) ?? ""
        guard !normalizedText.isEmpty else {
            return nil
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(location: 0, length: (normalizedText as NSString).length)
        guard let date = detector.matches(in: normalizedText, options: [], range: range).first?.date else {
            return nil
        }
        return Self.iso8601Local.string(from: date)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Local: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
        options: [.caseInsensitive]
    )
}

struct HeuristicMagicianIntentRouter: MagicianIntentRouting {
    private let schemaValidator = MagicianIntentSchemaValidator()

    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelection = selection?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !normalizedCommand.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "指令为空，请再说一次。",
                debugMessage: "command empty",
                recoverAction: "retry_command"
            )
        }

        if containsUnsupportedSearchIntent(normalizedCommand) {
            throw unsupportedSearchIntentError()
        }

        let lowered = normalizedCommand.lowercased()
        let candidate: MagicianFeatureID
        if containsAny(lowered, keywords: ["日程", "会议", "calendar", "约", "安排", "提醒"]) {
            candidate = .createEvent
        } else if containsAny(lowered, keywords: ["备忘录", "note", "记下来", "记到", "记一下", "记一条", "记录一下", "写进备忘录"]) {
            candidate = .createNote
        } else if containsAny(lowered, keywords: ["邮件", "mail", "email", "草稿", "发给", "发邮件", "写邮件", "邮箱"]) {
            candidate = .composeEmailDraft
        } else {
            candidate = .textTransform
        }

        let resolvedIntent = resolveEnabledFeature(candidate, enabledFeatures: enabledFeatures)
        var params = MagicianIntentParams.empty
        switch resolvedIntent {
        case .textTransform:
            params.mode = resolveTransformMode(from: lowered)
            params.targetLanguage = detectTargetLanguage(from: lowered)
        case .createEvent:
            params.title = resolvedEventTitle(
                command: normalizedCommand,
                selection: normalizedSelection
            )
        case .createNote:
            params.noteBody = resolvedNoteBody(
                command: normalizedCommand,
                selection: normalizedSelection
            )
        case .composeEmailDraft:
            params.mailDeliveryMode = resolvedMailDeliveryMode(from: normalizedCommand)
            params.mailSubject = resolvedMailSubject(
                command: normalizedCommand,
                selection: normalizedSelection
            )
            params.mailBody = resolvedMailBody(
                command: normalizedCommand,
                selection: normalizedSelection
            )
            params.mailTo = detectEmails(from: normalizedCommand)
            params.mailRecipientHints = detectRecipientHints(
                from: normalizedCommand,
                excludingEmails: params.mailTo ?? []
            )
        }

        let draftIntent = MagicianIntent(
            intent: resolvedIntent,
            confidence: resolvedIntent == candidate ? 0.86 : 0.52,
            sourceText: normalizedSelection,
            params: params
        )
        return try schemaValidator.validate(
            draftIntent,
            enabledFeatures: enabledFeatures,
            command: normalizedCommand,
            selection: normalizedSelection
        )
    }

    private func containsAny(_ value: String, keywords: [String]) -> Bool {
        keywords.contains { value.contains($0) }
    }

    private func resolveEnabledFeature(
        _ candidate: MagicianFeatureID,
        enabledFeatures: Set<MagicianFeatureID>
    ) -> MagicianFeatureID {
        if enabledFeatures.contains(candidate) {
            return candidate
        }
        if enabledFeatures.contains(.textTransform) {
            return .textTransform
        }
        if let first = MagicianFeatureID.allCases.first(where: { enabledFeatures.contains($0) }) {
            return first
        }
        return candidate
    }

    private func resolveTransformMode(from lowerCommand: String) -> MagicianTransformMode {
        if containsAny(lowerCommand, keywords: ["翻译", "translate", "翻成", "翻为"]) {
            return .translate
        }
        if containsAny(lowerCommand, keywords: ["扩写", "展开", "详细", "丰富"]) {
            return .expand
        }
        if containsAny(lowerCommand, keywords: ["精简", "简短", "压缩", "shorten", "condense"]) {
            return .shorten
        }
        if containsAny(lowerCommand, keywords: ["纠错", "改错", "检查错误", "fix"]) {
            return .fix
        }
        return .polish
    }

    private func detectTargetLanguage(from lowerCommand: String) -> String? {
        let mapping: [(String, String)] = [
            ("日语", "Japanese"),
            ("japanese", "Japanese"),
            ("英语", "English"),
            ("english", "English"),
            ("中文", "Chinese"),
            ("chinese", "Chinese"),
            ("韩语", "Korean"),
            ("korean", "Korean"),
            ("法语", "French"),
            ("french", "French"),
            ("德语", "German"),
            ("german", "German"),
            ("西班牙语", "Spanish"),
            ("spanish", "Spanish")
        ]
        for (token, language) in mapping where lowerCommand.contains(token) {
            return language
        }
        return nil
    }

    private func detectEmails(from text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        let matches = regex.matches(in: text, options: [], range: range)
        let emails = matches.compactMap { match -> String? in
            guard let matchRange = Range(match.range, in: text) else {
                return nil
            }
            return String(text[matchRange])
        }
        return emails.isEmpty ? nil : emails
    }

    private func detectRecipientHints(
        from text: String,
        excludingEmails emails: [String]
    ) -> [String]? {
        let excludedKeys = Set(emails.map(MailAddressBookStore.normalizedLookupKey))
        let markers = ["发给", "给", "寄给", "写给", "to"]
        var hints: [String] = []
        for marker in markers {
            guard let markerRange = text.range(of: marker, options: [.caseInsensitive]) else {
                continue
            }
            var candidate = text[markerRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stopTokens = ["主题", "内容", "正文", "发邮件", "写邮件", "邮件"]
            for stopToken in stopTokens {
                if let stopRange = candidate.range(of: stopToken, options: [.caseInsensitive]) {
                    candidate = String(candidate[..<stopRange.lowerBound])
                }
            }
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }
            let key = MailAddressBookStore.normalizedLookupKey(value)
            guard !excludedKeys.contains(key) else {
                continue
            }
            hints.append(value)
        }
        let normalized = hints.reduce(into: [String]()) { partialResult, item in
            if !partialResult.contains(where: {
                MailAddressBookStore.normalizedLookupKey($0) == MailAddressBookStore.normalizedLookupKey(item)
            }) {
                partialResult.append(item)
            }
        }
        return normalized.isEmpty ? nil : normalized
    }

    private func resolvedMailDeliveryMode(from command: String) -> MagicianMailDeliveryMode {
        let lowered = command.lowercased()
        if ["草拟", "草稿", "draft", "整理成邮件", "整理一下邮件"].contains(where: { lowered.contains($0) }) {
            return .draftOnly
        }
        if ["发送", "发给", "寄给", "发出", "send"].contains(where: { lowered.contains($0) }) {
            return .autoSendIfResolved
        }
        return .draftOnly
    }

    private func resolvedEventTitle(command: String, selection: String) -> String {
        if !selection.isEmpty {
            return String(selection.prefix(60))
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "安排", "创建", "建", "日程", "会议", "calendar", "event"]
        )
        if !reduced.isEmpty {
            return String(reduced.prefix(60))
        }
        return String(command.prefix(60))
    }

    private func resolvedNoteBody(command: String, selection: String) -> String {
        if !selection.isEmpty {
            return selection
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "记到", "记到备忘录", "记下来", "记一下", "记录一下", "备忘录", "note"]
        )
        return reduced.isEmpty ? command : reduced
    }

    private func resolvedMailSubject(command: String, selection: String) -> String {
        if let explicit = extractTrailingPhrase(
            in: command,
            markers: ["主题是", "主题:", "主题：", "subject:", "subject is"]
        ) {
            return String(explicit.prefix(48))
        }
        if !selection.isEmpty {
            return String(selection.prefix(48))
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "整理", "邮件", "草稿", "发给", "发邮件", "写邮件", "email", "mail"]
        )
        if !reduced.isEmpty {
            return String(reduced.prefix(48))
        }
        return String(command.prefix(48))
    }

    private func resolvedMailBody(command: String, selection: String) -> String {
        if !selection.isEmpty {
            return selection
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "整理成", "邮件", "草稿", "发给", "发邮件", "写邮件", "email", "mail", "主题是", "subject"]
        )
        return reduced.isEmpty ? command : reduced
    }

    private func compacted(_ text: String, removing tokens: [String]) -> String {
        var value = text
        for token in tokens {
            value = value.replacingOccurrences(
                of: token,
                with: "",
                options: [.caseInsensitive]
            )
        }
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTrailingPhrase(in text: String, markers: [String]) -> String? {
        for marker in markers {
            guard let range = text.range(of: marker, options: [.caseInsensitive]) else {
                continue
            }
            let value = text[range.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct LLMMagicianIntentRouter: MagicianIntentRouting {
    private let providerSettingsStore: ProviderSettingsStore
    private let generationProvider: any TextGenerationProvider
    private let schemaValidator: MagicianIntentSchemaValidator
    private let classifierPromptBuilder: MagicianIntentClassifierPromptBuilder
    private let eventPromptBuilder: MagicianEventPromptBuilder
    private let notePromptBuilder: MagicianNotePromptBuilder
    private let emailPromptBuilder: MagicianEmailPromptBuilder
    private let mailComposerPromptBuilder: MagicianMailComposerPromptBuilder

    init(
        providerSettingsStore: ProviderSettingsStore,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        schemaValidator: MagicianIntentSchemaValidator = MagicianIntentSchemaValidator(),
        classifierPromptBuilder: MagicianIntentClassifierPromptBuilder = MagicianIntentClassifierPromptBuilder(),
        eventPromptBuilder: MagicianEventPromptBuilder = MagicianEventPromptBuilder(),
        notePromptBuilder: MagicianNotePromptBuilder = MagicianNotePromptBuilder(),
        emailPromptBuilder: MagicianEmailPromptBuilder = MagicianEmailPromptBuilder(),
        mailComposerPromptBuilder: MagicianMailComposerPromptBuilder = MagicianMailComposerPromptBuilder()
    ) {
        self.providerSettingsStore = providerSettingsStore
        self.generationProvider = generationProvider
        self.schemaValidator = schemaValidator
        self.classifierPromptBuilder = classifierPromptBuilder
        self.eventPromptBuilder = eventPromptBuilder
        self.notePromptBuilder = notePromptBuilder
        self.emailPromptBuilder = emailPromptBuilder
        self.mailComposerPromptBuilder = mailComposerPromptBuilder
    }

    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent {
        if enabledFeatures.isEmpty {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "魔术先生能力都还没开启，请先在设置页打开至少一个开关。",
                debugMessage: "enabledFeatures empty",
                recoverAction: "open_magician_settings"
            )
        }

        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelection = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedCommand.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "指令为空，请再说一次。",
                debugMessage: "command empty",
                recoverAction: "retry_command"
            )
        }

        if containsUnsupportedSearchIntent(normalizedCommand) {
            throw unsupportedSearchIntentError()
        }

        if !providerSettingsStore.isRewriteConfigurationValid {
            let message = providerSettingsStore.rewriteConfigurationValidationMessage
                ?? "文本模型配置无效。"
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "魔术先生需要可用的文本模型，请先到设置页修正配置。",
                debugMessage: message,
                recoverAction: "open_provider_settings"
            )
        }

        let key = (try? providerSettingsStore.loadAPIKeyForRewriteProvider())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "魔术先生需要文本模型 API 密钥，请先到设置页填写。",
                debugMessage: "rewrite API key missing",
                recoverAction: "open_provider_settings"
            )
        }

        do {
            let classified = try await classifyIntent(
                command: normalizedCommand,
                selection: normalizedSelection,
                enabledFeatures: enabledFeatures,
                apiKey: key
            )

            if classified.intent == .textTransform {
                return try schemaValidator.validate(
                    MagicianIntent(
                        intent: .textTransform,
                        confidence: classified.confidence,
                        sourceText: normalizedSelection,
                        params: .empty
                    ),
                    enabledFeatures: enabledFeatures,
                    command: normalizedCommand,
                    selection: normalizedSelection
                )
            }

            let extraction = try await extractPayload(
                for: classified.intent,
                command: normalizedCommand,
                selection: normalizedSelection,
                apiKey: key
            )
            let draftIntent = MagicianIntent(
                intent: classified.intent,
                confidence: classified.confidence,
                sourceText: extraction.sourceText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                params: extraction.params
            )
            let normalizedIntent = normalizeLLMIntent(
                draftIntent,
                command: normalizedCommand,
                selection: normalizedSelection
            )
            return try schemaValidator.validate(
                normalizedIntent,
                enabledFeatures: enabledFeatures,
                command: normalizedCommand,
                selection: normalizedSelection
            )
        } catch let magicianError as MagicianError {
            throw magicianError
        } catch {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "文本模型没能稳定解析这条指令，请重试或检查设置。",
                debugMessage: error.localizedDescription,
                recoverAction: "retry_command"
            )
        }
    }

    private func classifyIntent(
        command: String,
        selection: String,
        enabledFeatures: Set<MagicianFeatureID>,
        apiKey: String
    ) async throws -> MagicianIntentClassification {
        let template = classifierPromptBuilder.build(
            enabledFeatures: enabledFeatures,
            command: command,
            selection: selection
        )
        let response = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.1,
                maxOutputTokens: 180
            ),
            configuration: providerSettingsStore.rewriteConfiguration,
            apiKey: apiKey
        )
        return try decodePayload(
            from: response.outputText,
            debugPrefix: "intent classifier"
        )
    }

    private func extractPayload(
        for intent: MagicianFeatureID,
        command: String,
        selection: String,
        apiKey: String
    ) async throws -> MagicianIntentExtractionPayload {
        if intent == .composeEmailDraft {
            return try await extractMailPayload(
                command: command,
                selection: selection,
                apiKey: apiKey
            )
        }

        let template = extractionPromptTemplate(
            for: intent,
            command: command,
            selection: selection
        )
        let response = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.1,
                maxOutputTokens: 320
            ),
            configuration: providerSettingsStore.rewriteConfiguration,
            apiKey: apiKey
        )
        return try decodePayload(
            from: response.outputText,
            debugPrefix: "\(intent.rawValue) extractor"
        )
    }

    private func extractMailPayload(
        command: String,
        selection: String,
        apiKey: String
    ) async throws -> MagicianIntentExtractionPayload {
        let extractorTemplate = emailPromptBuilder.build(command: command, selection: selection)
        let extractorResponse = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: extractorTemplate.systemPrompt,
                userPrompt: extractorTemplate.userPrompt,
                temperature: 0.1,
                maxOutputTokens: 260
            ),
            configuration: providerSettingsStore.rewriteConfiguration,
            apiKey: apiKey
        )
        let extracted: MagicianIntentExtractionPayload = try decodePayload(
            from: extractorResponse.outputText,
            debugPrefix: "compose_email_draft mail intent extractor"
        )

        let composerTemplate = mailComposerPromptBuilder.build(command: command, selection: selection)
        let composerResponse = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: composerTemplate.systemPrompt,
                userPrompt: composerTemplate.userPrompt,
                temperature: 0.15,
                maxOutputTokens: 420
            ),
            configuration: providerSettingsStore.rewriteConfiguration,
            apiKey: apiKey
        )
        let composed: MagicianMailComposerPayload = try decodePayload(
            from: composerResponse.outputText,
            debugPrefix: "compose_email_draft mail composer"
        )

        var params = extracted.params
        params.mailSubject = composed.mailSubject
        params.mailBody = composed.mailBody
        return MagicianIntentExtractionPayload(
            sourceText: extracted.sourceText,
            params: params
        )
    }

    private func extractionPromptTemplate(
        for intent: MagicianFeatureID,
        command: String,
        selection: String
    ) -> RewritePromptTemplate {
        switch intent {
        case .textTransform:
            return classifierPromptBuilder.build(
                enabledFeatures: [.textTransform],
                command: command,
                selection: selection
            )
        case .createEvent:
            return eventPromptBuilder.build(command: command, selection: selection)
        case .createNote:
            return notePromptBuilder.build(command: command, selection: selection)
        case .composeEmailDraft:
            return emailPromptBuilder.build(command: command, selection: selection)
        }
    }

    private func decodePayload<T: Decodable>(
        from outputText: String,
        debugPrefix: String
    ) throws -> T {
        let jsonText = extractJSONObject(from: outputText)
        guard let data = jsonText.data(using: .utf8) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: userFacingDecodeMessage(for: debugPrefix),
                debugMessage: "\(debugPrefix) JSON utf8 decode failed",
                recoverAction: "retry_command"
            )
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: userFacingDecodeMessage(for: debugPrefix),
                debugMessage: "\(debugPrefix) JSON decode error: \(error.localizedDescription)",
                recoverAction: "retry_command"
            )
        }
    }

    private func userFacingDecodeMessage(for debugPrefix: String) -> String {
        if debugPrefix.contains("compose_email_draft") {
            return "邮件助手没能整理出可发送的主题、正文或收件人提示，请换个说法再试。"
        }
        return "没听清这条命令的意图，请换个说法再试。"
    }

    private func extractJSONObject(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped: String
        if trimmed.hasPrefix("```") {
            stripped = trimmed
                .replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stripped = trimmed
        }

        guard
            let firstBrace = stripped.firstIndex(of: "{"),
            let lastBrace = stripped.lastIndex(of: "}")
        else {
            return stripped
        }
        return String(stripped[firstBrace...lastBrace])
    }

    private func normalizeLLMIntent(
        _ intent: MagicianIntent,
        command: String,
        selection: String
    ) -> MagicianIntent {
        var params = intent.params
        var sourceText = intent.sourceText
        let hasSelection = !selection.isEmpty

        switch intent.intent {
        case .textTransform:
            if hasSelection {
                sourceText = selection
            }

        case .createEvent:
            if hasSelection {
                sourceText = selection
                if shouldUseSelectionAsContent(
                    candidate: params.title,
                        command: command,
                        actionTokens: ["日程", "建立日程", "创建日程", "建日程", "会议", "calendar", "event"]
                    ) {
                        params.title = String(selection.prefix(60))
                    }
                if (params.notes ?? "").isEmpty {
                    params.notes = selection
                }
            }

        case .createNote:
            if hasSelection {
                sourceText = selection
                if shouldUseSelectionAsContent(
                    candidate: params.noteBody,
                    command: command,
                    actionTokens: ["备忘录", "写进备忘录", "写入备忘录", "记下来", "记到", "note"]
                ) {
                    params.noteBody = selection
                }
            }

        case .composeEmailDraft:
            if params.mailDeliveryMode == nil {
                params.mailDeliveryMode = resolvedMailDeliveryMode(from: command)
            }
            if hasSelection {
                sourceText = selection
                params.mailBody = sanitizedMailBody(
                    candidate: params.mailBody,
                    command: command,
                    selection: selection,
                    sourceText: selection
                )
                params.mailSubject = sanitizedMailSubject(
                    candidate: params.mailSubject,
                    command: command,
                    selection: selection,
                    sourceText: selection
                )
            } else {
                let fallbackSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? command
                    : sourceText
                params.mailBody = sanitizedMailBody(
                    candidate: params.mailBody,
                    command: command,
                    selection: selection,
                    sourceText: fallbackSource
                )
                params.mailSubject = sanitizedMailSubject(
                    candidate: params.mailSubject,
                    command: command,
                    selection: selection,
                    sourceText: fallbackSource
                )
            }
        }

        return MagicianIntent(
            intent: intent.intent,
            confidence: intent.confidence,
            sourceText: sourceText,
            params: params
        )
    }

    private func shouldUseSelectionAsContent(
        candidate: String?,
        command: String,
        actionTokens: [String]
    ) -> Bool {
        guard let candidate else {
            return true
        }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }
        return isLikelyInstructionPhrase(
            trimmed,
            command: command,
            actionTokens: actionTokens
        )
    }

    private func isLikelyInstructionPhrase(
        _ text: String,
        command: String,
        actionTokens: [String]
    ) -> Bool {
        let compactText = compactIntentText(text)
        guard !compactText.isEmpty else {
            return true
        }
        if compactText == compactIntentText(command) {
            return true
        }

        var reduced = compactText
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

    private func compactIntentText(_ value: String) -> String {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return value.lowercased()
            .components(separatedBy: separators)
            .joined()
    }

    private func resolvedMailDeliveryMode(from command: String) -> MagicianMailDeliveryMode {
        let lowered = command.lowercased()
        if ["草拟", "草稿", "draft", "整理成邮件", "整理一下邮件"].contains(where: { lowered.contains($0) }) {
            return .draftOnly
        }
        if ["发送", "发给", "寄给", "发出", "send"].contains(where: { lowered.contains($0) }) {
            return .autoSendIfResolved
        }
        return .draftOnly
    }

    private func sanitizedMailSubject(
        candidate: String?,
        command: String,
        selection: String,
        sourceText: String
    ) -> String? {
        if
            let candidate,
            !candidate.isEmpty,
            !shouldUseSelectionAsContent(
                candidate: candidate,
                command: command,
                actionTokens: ["邮件", "草稿", "mail", "email", "主题", "subject", "发送", "发给"]
            )
        {
            return String(candidate.prefix(48))
        }

        let fallback = [sourceText, selection, command]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let fallback else {
            return nil
        }
        return String(fallback.prefix(48))
    }

    private func sanitizedMailBody(
        candidate: String?,
        command: String,
        selection: String,
        sourceText: String
    ) -> String? {
        if
            let candidate,
            !candidate.isEmpty,
            !shouldUseSelectionAsContent(
                candidate: candidate,
                command: command,
                actionTokens: ["邮件", "草稿", "mail", "email", "发邮件", "写邮件", "发送", "发给"]
            )
        {
            return candidate
        }

        let fallback = [sourceText, selection, command]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return fallback
    }
}
