import Foundation

@MainActor
protocol MagicianIntentRouting {
    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent
}

struct MagicianIntentSchemaValidator {
    func validate(
        _ intent: MagicianIntent,
        enabledFeatures: Set<MagicianFeatureID>,
        command: String? = nil
    ) throws -> MagicianIntent {
        guard enabledFeatures.contains(intent.intent) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "这条指令对应的能力还没开启，请先到魔法师页面打开开关。",
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
        params.query = normalized(params.query)
        params.title = normalized(params.title)
        params.startAt = normalizeISO8601String(params.startAt)
        params.endAt = normalizeISO8601String(params.endAt)
        params.location = normalized(params.location)
        params.noteBody = normalized(params.noteBody)
        params.mailSubject = normalized(params.mailSubject)
        params.mailBody = normalized(params.mailBody)
        params.mailTo = normalizeEmails(params.mailTo)

        let normalizedCommand = normalized(command) ?? ""
        let sourceText = normalized(intent.sourceText) ?? ""

        switch intent.intent {
        case .textTransform:
            guard !sourceText.isEmpty else {
                throw MagicianError(
                    code: .selectionEmpty,
                    userMessage: "文字处理需要先选中内容再说指令。",
                    debugMessage: "text_transform sourceText empty",
                    recoverAction: "select_text_first"
                )
            }
        case .webSearch:
            if (params.query ?? "").isEmpty {
                let fallback = sourceText.isEmpty ? normalizedCommand : sourceText
                params.query = fallback.isEmpty ? nil : fallback
            }
        case .createEvent:
            if (params.title ?? "").isEmpty {
                let fallbackSource = sourceText.isEmpty ? normalizedCommand : sourceText
                let title = fallbackSource.trimmingCharacters(in: .whitespacesAndNewlines)
                params.title = title.isEmpty ? nil : String(title.prefix(60))
            }
        case .createNote:
            if (params.noteBody ?? "").isEmpty {
                let fallback = sourceText.isEmpty ? normalizedCommand : sourceText
                params.noteBody = fallback.isEmpty ? nil : fallback
            }
        case .composeEmailDraft:
            if (params.mailBody ?? "").isEmpty {
                let fallback = sourceText.isEmpty ? normalizedCommand : sourceText
                params.mailBody = fallback.isEmpty ? nil : fallback
            }
            if (params.mailSubject ?? "").isEmpty {
                let fallbackSource = sourceText.isEmpty ? normalizedCommand : sourceText
                let subject = fallbackSource.trimmingCharacters(in: .whitespacesAndNewlines)
                params.mailSubject = subject.isEmpty ? nil : String(subject.prefix(24))
            }
        }

        return MagicianIntent(
            intent: intent.intent,
            confidence: confidence,
            sourceText: sourceText,
            params: params
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

    private func normalizeEmails(_ values: [String]?) -> [String]? {
        guard let values else {
            return nil
        }
        let filtered = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { Self.emailRegex.firstMatch(in: $0, options: [], range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }
        return filtered.isEmpty ? nil : filtered
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

        let lowered = normalizedCommand.lowercased()
        let candidate: MagicianFeatureID
        if containsAny(lowered, keywords: ["搜索", "查一下", "查一查", "google", "search"]) {
            candidate = .webSearch
        } else if containsAny(lowered, keywords: ["日程", "会议", "calendar", "约", "安排", "提醒"]) {
            candidate = .createEvent
        } else if containsAny(lowered, keywords: ["备忘录", "note", "记下来", "记到"]) {
            candidate = .createNote
        } else if containsAny(lowered, keywords: ["邮件", "mail", "email", "草稿", "发给"]) {
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
        case .webSearch:
            params.query = resolvedWebQuery(
                command: normalizedCommand,
                selection: normalizedSelection
            )
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
            params.mailSubject = resolvedMailSubject(
                command: normalizedCommand,
                selection: normalizedSelection
            )
            params.mailBody = resolvedMailBody(
                command: normalizedCommand,
                selection: normalizedSelection
            )
            params.mailTo = detectEmails(from: normalizedCommand)
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
            command: normalizedCommand
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

    private func resolvedWebQuery(command: String, selection: String) -> String {
        if !selection.isEmpty {
            return selection
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "一下", "搜索", "查一下", "查一查", "google", "search"]
        )
        return reduced.isEmpty ? command : reduced
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
            removing: ["帮我", "请", "记到", "记到备忘录", "记下来", "备忘录", "note"]
        )
        return reduced.isEmpty ? command : reduced
    }

    private func resolvedMailSubject(command: String, selection: String) -> String {
        if let explicit = extractTrailingPhrase(
            in: command,
            markers: ["主题是", "主题:", "主题：", "subject:", "subject is"]
        ) {
            return String(explicit.prefix(24))
        }
        if !selection.isEmpty {
            return String(selection.prefix(24))
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "整理", "邮件", "草稿", "发给", "email", "mail"]
        )
        if !reduced.isEmpty {
            return String(reduced.prefix(24))
        }
        return String(command.prefix(24))
    }

    private func resolvedMailBody(command: String, selection: String) -> String {
        if !selection.isEmpty {
            return selection
        }
        let reduced = compacted(
            command,
            removing: ["帮我", "请", "整理成", "邮件", "草稿", "发给", "email", "mail", "主题是", "subject"]
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

    init(
        providerSettingsStore: ProviderSettingsStore,
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        schemaValidator: MagicianIntentSchemaValidator = MagicianIntentSchemaValidator()
    ) {
        self.providerSettingsStore = providerSettingsStore
        self.generationProvider = generationProvider
        self.schemaValidator = schemaValidator
    }

    func route(
        command: String,
        selection: String?,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent {
        if enabledFeatures.isEmpty {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "魔法师能力都还没开启，请先在设置页打开至少一个开关。",
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

        if !providerSettingsStore.isRewriteConfigurationValid {
            return try await HeuristicMagicianIntentRouter().route(
                command: normalizedCommand,
                selection: normalizedSelection,
                enabledFeatures: enabledFeatures
            )
        }

        let key = (try? providerSettingsStore.loadAPIKeyForRewriteProvider())?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else {
            return try await HeuristicMagicianIntentRouter().route(
                command: normalizedCommand,
                selection: normalizedSelection,
                enabledFeatures: enabledFeatures
            )
        }

        do {
            let response = try await generationProvider.generateText(
                request: TextGenerationRequest(
                    systemPrompt: llmSystemPrompt(enabledFeatures: enabledFeatures),
                    userPrompt: llmUserPrompt(command: normalizedCommand, selection: normalizedSelection),
                    temperature: 0.1,
                    maxOutputTokens: 360
                ),
                configuration: providerSettingsStore.rewriteConfiguration,
                apiKey: key
            )
            let decoded = try decodeIntent(from: response.outputText)
            return try schemaValidator.validate(
                decoded,
                enabledFeatures: enabledFeatures,
                command: normalizedCommand
            )
        } catch {
            return try await HeuristicMagicianIntentRouter().route(
                command: normalizedCommand,
                selection: normalizedSelection,
                enabledFeatures: enabledFeatures
            )
        }
    }

    private func decodeIntent(from outputText: String) throws -> MagicianIntent {
        let jsonText = extractJSONObject(from: outputText)
        guard let data = jsonText.data(using: .utf8) else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没听清这条命令的意图，请换个说法再试。",
                debugMessage: "intent JSON utf8 decode failed",
                recoverAction: "retry_command"
            )
        }
        do {
            return try JSONDecoder().decode(MagicianIntent.self, from: data)
        } catch {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没听清这条命令的意图，请换个说法再试。",
                debugMessage: "intent JSON decode error: \(error.localizedDescription)",
                recoverAction: "retry_command"
            )
        }
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

    private func llmSystemPrompt(enabledFeatures: Set<MagicianFeatureID>) -> String {
        let allowedIntents = MagicianFeatureID.allCases
            .filter { enabledFeatures.contains($0) }
            .map(\.rawValue)
            .joined(separator: ", ")

        return """
        You are an intent router for a macOS voice assistant.
        Return JSON only and never output markdown fences.

        Allowed intent values (must choose one):
        \(allowedIntents)

        Output JSON schema:
        {
          "intent": "text_transform | web_search | create_event | create_note | compose_email_draft",
          "confidence": 0.0,
          "sourceText": "string",
          "params": {
            "mode": "translate | polish | expand | shorten | fix",
            "targetLanguage": "string",
            "tone": "string",
            "query": "string",
            "title": "string",
            "startAt": "ISO8601",
            "endAt": "ISO8601",
            "location": "string",
            "noteBody": "string",
            "mailTo": ["a@example.com"],
            "mailSubject": "string",
            "mailBody": "string"
          }
        }

        Rules:
        1) intent must be one of allowed values above.
        2) confidence between 0 and 1.
        3) Keep params minimal and only include useful fields.
        4) If intent is text_transform, sourceText must be the selected text and cannot be empty.
        5) For other intents, sourceText can be empty when there is no selected text.
        """
    }

    private func llmUserPrompt(command: String, selection: String) -> String {
        """
        Spoken command:
        \(command)

        Selected text:
        \(selection.isEmpty ? "(empty)" : selection)
        """
    }
}
