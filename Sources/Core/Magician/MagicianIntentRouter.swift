import Foundation

@MainActor
protocol MagicianIntentRouting {
    func route(
        command: String,
        selection: String,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent
}

struct MagicianIntentSchemaValidator {
    func validate(
        _ intent: MagicianIntent,
        enabledFeatures: Set<MagicianFeatureID>
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

        let sourceText = normalized(intent.sourceText) ?? ""
        if sourceText.isEmpty {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "没拿到选中文本，请先选中内容再说指令。",
                debugMessage: "sourceText empty after normalize",
                recoverAction: "select_text_first"
            )
        }

        if intent.intent == .webSearch, (params.query ?? "").isEmpty {
            params.query = sourceText
        }
        if intent.intent == .createNote, (params.noteBody ?? "").isEmpty {
            params.noteBody = sourceText
        }
        if intent.intent == .composeEmailDraft, (params.mailBody ?? "").isEmpty {
            params.mailBody = sourceText
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
    func route(
        command: String,
        selection: String,
        enabledFeatures: Set<MagicianFeatureID>
    ) async throws -> MagicianIntent {
        let normalizedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedCommand.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "指令为空，请再说一次。",
                debugMessage: "command empty",
                recoverAction: "retry_command"
            )
        }

        guard !normalizedSelection.isEmpty else {
            throw MagicianError(
                code: .selectionEmpty,
                userMessage: "没拿到选中文本，请先选中内容再说指令。",
                debugMessage: "selection empty",
                recoverAction: "select_text_first"
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
            params.query = normalizedSelection
        case .createEvent:
            params.title = String(normalizedSelection.prefix(20))
        case .createNote:
            params.noteBody = normalizedSelection
        case .composeEmailDraft:
            params.mailSubject = String(normalizedSelection.prefix(20))
            params.mailBody = normalizedSelection
            params.mailTo = detectEmails(from: normalizedCommand)
        }

        return MagicianIntent(
            intent: resolvedIntent,
            confidence: resolvedIntent == candidate ? 0.86 : 0.52,
            sourceText: normalizedSelection,
            params: params
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
        selection: String,
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
        let normalizedSelection = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCommand.isEmpty else {
            throw MagicianError(
                code: .intentParseFailed,
                userMessage: "指令为空，请再说一次。",
                debugMessage: "command empty",
                recoverAction: "retry_command"
            )
        }
        guard !normalizedSelection.isEmpty else {
            throw MagicianError(
                code: .selectionEmpty,
                userMessage: "没拿到选中文本，请先选中内容再说指令。",
                debugMessage: "selection empty",
                recoverAction: "select_text_first"
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
            return try schemaValidator.validate(decoded, enabledFeatures: enabledFeatures)
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
        4) sourceText must be the provided selected text.
        """
    }

    private func llmUserPrompt(command: String, selection: String) -> String {
        """
        Spoken command:
        \(command)

        Selected text:
        \(selection)
        """
    }
}
