import Foundation

enum RewritePolishStyle: String, Equatable {
    case formal
    case casual
    case neutral
}

enum RewriteAction: Equatable {
    case translate(targetLanguage: String)
    case polish(style: RewritePolishStyle)
    case condense
    case structure
    case custom(command: String)

    var label: String {
        switch self {
        case let .translate(targetLanguage):
            return "翻译为\(targetLanguage)"
        case let .polish(style):
            switch style {
            case .formal:
                return "正式润色"
            case .casual:
                return "自然润色"
            case .neutral:
                return "润色"
            }
        case .condense:
            return "精简"
        case .structure:
            return "结构化"
        case let .custom(command):
            return shortCommandLabel(for: command)
        }
    }

    private func shortCommandLabel(for command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "按指令处理"
        }
        if trimmed.count <= 14 {
            return trimmed
        }
        return "\(trimmed.prefix(14))..."
    }
}

struct RewriteIntent: Equatable {
    let action: RewriteAction
    let sourceInstruction: String
}

struct SelectionRewriteRequest {
    let selectedText: String
    let spokenInstruction: String
    let focusContext: FocusedAppContext
    let outputBias: AppOutputBias
    let appPrompt: String?
    let userSystemPrompt: String?
}

struct SelectionRewriteResult: Equatable {
    let rewrittenText: String
    let actionLabel: String
    let providerName: String
    let modelName: String
}

struct DictationPostProcessRequest: Equatable {
    let transcript: String
    let focusContext: FocusedAppContext
    let appPrompt: String?
    let userSystemPrompt: String
}

struct DictationPostProcessResult: Equatable {
    let outputText: String
    let providerName: String
    let modelName: String
}

enum RewriteProviderError: LocalizedError {
    case noSelectedText
    case emptyInstruction
    case generationFailed(description: String)
    case invalidGeneratedText

    var errorDescription: String? {
        switch self {
        case .noSelectedText:
            return "No selected text is available for rewrite."
        case .emptyInstruction:
            return "Rewrite instruction is empty."
        case let .generationFailed(description):
            return "Rewrite generation failed: \(description)"
        case .invalidGeneratedText:
            return "Generated rewrite text is empty."
        }
    }
}

struct TextGenerationRequest {
    let systemPrompt: String
    let userPrompt: String
    let temperature: Double
    let maxOutputTokens: Int?
}

struct TextGenerationResult: Equatable {
    let providerType: ProviderType
    let providerName: String
    let modelName: String
    let outputText: String
}

protocol TextGenerationProvider: Sendable {
    var supportedProviderTypes: [ProviderType] { get }
    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult
}

protocol RewriteProvider {
    var supportedProviderTypes: [ProviderType] { get }
    func rewrite(
        request: SelectionRewriteRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> SelectionRewriteResult
}

protocol DictationPostProcessor {
    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult
}

struct RewriteProviderRegistry {
    private let providersByType: [ProviderType: any RewriteProvider]

    init(providers: [any RewriteProvider]) {
        var map: [ProviderType: any RewriteProvider] = [:]
        for provider in providers {
            for type in provider.supportedProviderTypes {
                map[type] = provider
            }
        }
        providersByType = map
    }

    func provider(for providerType: ProviderType) -> (any RewriteProvider)? {
        providersByType[providerType]
    }
}

struct RewriteIntentParser {
    func parse(
        instruction: String,
        defaultOutputBias: AppOutputBias = .neutral
    ) throws -> RewriteIntent {
        let normalized = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw RewriteProviderError.emptyInstruction
        }

        let lowercased = normalized.lowercased()

        if lowercased.contains("翻译") || lowercased.contains("translate") {
            let target = detectTargetLanguage(from: lowercased) ?? "English"
            return RewriteIntent(
                action: .translate(targetLanguage: target),
                sourceInstruction: normalized
            )
        }

        if shouldPreferCustomTransformation(for: lowercased) {
            return RewriteIntent(
                action: .custom(command: normalized),
                sourceInstruction: normalized
            )
        }

        if lowercased.contains("口语") || lowercased.contains("casual") || lowercased.contains("自然一点") {
            return RewriteIntent(
                action: .polish(style: .casual),
                sourceInstruction: normalized
            )
        }

        if lowercased.contains("正式") || lowercased.contains("formal") {
            return RewriteIntent(
                action: .polish(style: .formal),
                sourceInstruction: normalized
            )
        }

        if
            lowercased.contains("精简") ||
            lowercased.contains("简短") ||
            lowercased.contains("简化") ||
            lowercased.contains("condense") ||
            lowercased.contains("shorten")
        {
            return RewriteIntent(
                action: .condense,
                sourceInstruction: normalized
            )
        }

        if
            lowercased.contains("分点") ||
            lowercased.contains("结构化") ||
            lowercased.contains("整理成要点") ||
            lowercased.contains("整理成分点") ||
            lowercased.contains("bullet") ||
            lowercased.contains("outline")
        {
            return RewriteIntent(
                action: .structure,
                sourceInstruction: normalized
            )
        }

        if
            lowercased.contains("润色") ||
            lowercased.contains("polish") ||
            lowercased.contains("优化") ||
            lowercased.contains("improve")
        {
            if defaultOutputBias == .structured {
                return RewriteIntent(
                    action: .structure,
                    sourceInstruction: normalized
                )
            }
            return RewriteIntent(
                action: .polish(style: defaultOutputBias.rewritePolishStyle),
                sourceInstruction: normalized
            )
        }

        return RewriteIntent(
            action: .custom(command: normalized),
            sourceInstruction: normalized
        )
    }

    private func shouldPreferCustomTransformation(for instruction: String) -> Bool {
        let styleTokens = [
            "风格", "语气", "口吻", "写成", "改成", "变成", "转换成", "转换为",
            "改写成", "仿", "模仿", "像", "古诗", "诗词", "文言", "rap", "歌词"
        ]
        return styleTokens.contains { instruction.contains($0) }
    }

    private func detectTargetLanguage(from instruction: String) -> String? {
        let languageMap: [(String, String)] = [
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

        for (token, language) in languageMap where instruction.contains(token) {
            return language
        }

        return nil
    }
}

struct RewritePromptTemplate {
    let systemPrompt: String
    let userPrompt: String
}

struct DictationPostProcessPromptBuilder {
    func build(request: DictationPostProcessRequest) -> RewritePromptTemplate {
        let normalizedUserSystemPrompt = request.userSystemPrompt
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppPrompt = request.appPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let preferenceBlock = normalizedUserSystemPrompt.isEmpty
            ? "（无）"
            : normalizedUserSystemPrompt
        let appPromptBlock = normalizedAppPrompt.isEmpty
            ? "（无）"
            : normalizedAppPrompt

        let systemPrompt = """
        You are a precise dictation cleanup engine.
        Return only the final text with no explanations.
        Preserve the user's meaning.

        User preference system instruction:
        \(preferenceBlock)

        App-specific instruction:
        \(appPromptBlock)
        """

        let userPrompt = """
        App context:
        - appName: \(request.focusContext.appName)
        - bundleID: \(request.focusContext.bundleID)

        Raw transcript:
        <<<TEXT
        \(request.transcript)
        TEXT>>>
        """

        return RewritePromptTemplate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }
}

typealias RewritePromptBuilder = MagicianTextTransformPromptBuilder

struct OpenAIRewriteProvider: RewriteProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]

    private let generationProvider: any TextGenerationProvider
    private let promptBuilder: RewritePromptBuilder

    init(
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        promptBuilder: RewritePromptBuilder = RewritePromptBuilder()
    ) {
        self.generationProvider = generationProvider
        self.promptBuilder = promptBuilder
    }

    func rewrite(
        request: SelectionRewriteRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> SelectionRewriteResult {
        let selectedText = request.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else {
            throw RewriteProviderError.noSelectedText
        }

        let template = promptBuilder.build(
            intent: RewriteIntent(
                action: .custom(command: request.spokenInstruction),
                sourceInstruction: request.spokenInstruction
            ),
            request: request
        )

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.35,
                maxOutputTokens: 900
            ),
            configuration: configuration,
            apiKey: apiKey
        )

        let output = generation.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw RewriteProviderError.invalidGeneratedText
        }

        return SelectionRewriteResult(
            rewrittenText: output,
            actionLabel: MagicianTextTransformLabelResolver.label(for: request.spokenInstruction),
            providerName: generation.providerName,
            modelName: generation.modelName
        )
    }
}

struct LLMDictationPostProcessor: DictationPostProcessor {
    private let generationProvider: any TextGenerationProvider
    private let promptBuilder: DictationPostProcessPromptBuilder

    init(
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        promptBuilder: DictationPostProcessPromptBuilder = DictationPostProcessPromptBuilder()
    ) {
        self.generationProvider = generationProvider
        self.promptBuilder = promptBuilder
    }

    func process(
        request: DictationPostProcessRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> DictationPostProcessResult {
        let normalizedTranscript = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTranscript.isEmpty else {
            throw RewriteProviderError.invalidGeneratedText
        }

        let template = promptBuilder.build(
            request: DictationPostProcessRequest(
                transcript: normalizedTranscript,
                focusContext: request.focusContext,
                appPrompt: request.appPrompt,
                userSystemPrompt: request.userSystemPrompt
            )
        )

        let dynamicTokenBudget = max(120, min(420, normalizedTranscript.count * 2))

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.2,
                maxOutputTokens: dynamicTokenBudget
            ),
            configuration: configuration,
            apiKey: apiKey
        )

        let output = generation.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw RewriteProviderError.invalidGeneratedText
        }

        return DictationPostProcessResult(
            outputText: output,
            providerName: generation.providerName,
            modelName: generation.modelName
        )
    }
}

struct BrainstormContextComposeRequest: Equatable {
    let transcript: String
    let focusContext: FocusedAppContext
    let appPrompt: String?
    let userSystemPrompt: String?
}

struct BrainstormContextComposeResult: Equatable {
    let summaryText: String
    let dialogueText: String
    let providerName: String
    let modelName: String
}

protocol BrainstormContextComposer {
    func compose(
        request: BrainstormContextComposeRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> BrainstormContextComposeResult
}

struct BrainstormContextPromptBuilder {
    func build(request: BrainstormContextComposeRequest) -> RewritePromptTemplate {
        let normalizedUserSystemPrompt = request.userSystemPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedAppPrompt = request.appPrompt?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userPromptBlock = normalizedUserSystemPrompt.isEmpty
            ? "（无）"
            : normalizedUserSystemPrompt
        let appPromptBlock = normalizedAppPrompt.isEmpty
            ? "（无）"
            : normalizedAppPrompt

        let systemPrompt = """
        You are a brainstorming synthesis engine.
        Return only valid JSON. Do not add markdown fences.

        Hard rules:
        1) Output must include only two sections: concise conclusions and role dialogue.
        2) Conclusions must contain 3-5 items, one sentence per item, conclusion only.
        3) Dialogue must keep chronological order and use A/B/C role tags.
        4) Never output YAML, markdown, explanation, or extra fields.

        Priority when instructions conflict:
        1) Hard rules above
        2) App-specific instruction
        3) User preference instruction

        App-specific instruction (priority #2):
        \(appPromptBlock)

        User preference instruction (priority #3):
        \(userPromptBlock)
        """

        let userPrompt = """
        App context:
        - appName: \(request.focusContext.appName)
        - bundleID: \(request.focusContext.bundleID)

        Raw transcript:
        <<<TEXT
        \(request.transcript)
        TEXT>>>

        Output schema (JSON object):
        {
          "summaryPoints": ["...", "...", "..."],
          "dialogueLines": ["A: ...", "B: ..."]
        }
        """

        return RewritePromptTemplate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }
}

struct LLMBrainstormContextComposer: BrainstormContextComposer {
    private let generationProvider: any TextGenerationProvider
    private let promptBuilder: BrainstormContextPromptBuilder

    init(
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        promptBuilder: BrainstormContextPromptBuilder = BrainstormContextPromptBuilder()
    ) {
        self.generationProvider = generationProvider
        self.promptBuilder = promptBuilder
    }

    func compose(
        request: BrainstormContextComposeRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> BrainstormContextComposeResult {
        let normalized = request.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw RewriteProviderError.invalidGeneratedText
        }

        let template = promptBuilder.build(
            request: BrainstormContextComposeRequest(
                transcript: normalized,
                focusContext: request.focusContext,
                appPrompt: request.appPrompt,
                userSystemPrompt: request.userSystemPrompt
            )
        )

        let dynamicTokenBudget = Self.dynamicTokenBudget(for: normalized)
        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.2,
                maxOutputTokens: dynamicTokenBudget
            ),
            configuration: configuration,
            apiKey: apiKey
        )

        let output = generation.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw RewriteProviderError.invalidGeneratedText
        }
        let parsed = Self.parseBrainstormOutput(
            output,
            fallbackTranscript: normalized
        )

        return BrainstormContextComposeResult(
            summaryText: parsed.summaryText,
            dialogueText: parsed.dialogueText,
            providerName: generation.providerName,
            modelName: generation.modelName
        )
    }

    static func dynamicTokenBudget(for transcript: String) -> Int {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return max(220, min(1200, normalized.count * 2))
    }

    private static func parseBrainstormOutput(
        _ output: String,
        fallbackTranscript: String
    ) -> (summaryText: String, dialogueText: String) {
        if let parsed = parseJSONPayload(output) {
            let dialogue = parsed.dialogueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackDialogue(from: fallbackTranscript)
                : parsed.dialogueText
            return (parsed.summaryText, dialogue)
        }

        let stripped = stripMarkdownFence(output)
        if let parsed = parseJSONPayload(stripped) {
            let dialogue = parsed.dialogueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackDialogue(from: fallbackTranscript)
                : parsed.dialogueText
            return (parsed.summaryText, dialogue)
        }

        return (
            summaryText: fallbackSummary(from: fallbackTranscript),
            dialogueText: fallbackDialogue(from: fallbackTranscript)
        )
    }

    private static func parseJSONPayload(
        _ output: String
    ) -> (summaryText: String, dialogueText: String)? {
        guard
            let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data),
            let dictionary = json as? [String: Any]
        else {
            return nil
        }

        let summarySource = dictionary["summaryPoints"] ?? dictionary["summary"]
        let dialogueSource = dictionary["dialogueLines"] ?? dictionary["dialogue"]
        var summaryPoints = normalizeSummaryPoints(summarySource)
        let dialogueLines = normalizeDialogueLines(dialogueSource)

        if summaryPoints.count > 5 {
            summaryPoints = Array(summaryPoints.prefix(5))
        }

        let fallbackPoints = fallbackSummaryPoints()
        var fallbackIndex = 0
        while summaryPoints.count < 3, fallbackIndex < fallbackPoints.count {
            summaryPoints.append(fallbackPoints[fallbackIndex])
            fallbackIndex += 1
        }

        if summaryPoints.isEmpty {
            return nil
        }

        return (
            summaryText: summaryPoints.map { "- \($0)" }.joined(separator: "\n"),
            dialogueText: dialogueLines.joined(separator: "\n")
        )
    }

    private static func normalizeSummaryPoints(_ source: Any?) -> [String] {
        let rawItems: [String]
        if let values = source as? [Any] {
            rawItems = values.compactMap { $0 as? String }
        } else if let value = source as? String {
            rawItems = value.split(whereSeparator: \.isNewline).map(String.init)
        } else {
            rawItems = []
        }

        return rawItems
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^[-•\d\.\)\s]+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
    }

    private static func normalizeDialogueLines(_ source: Any?) -> [String] {
        let rawItems: [String]
        if let values = source as? [Any] {
            rawItems = values.compactMap { $0 as? String }
        } else if let value = source as? String {
            rawItems = value.split(whereSeparator: \.isNewline).map(String.init)
        } else {
            rawItems = []
        }

        return rawItems
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, line in
                if line.range(of: #"^[A-Z][A-Z0-9]*\s*[:：]"#, options: .regularExpression) != nil {
                    return line.replacingOccurrences(of: "：", with: ":")
                }
                let roles = ["A", "B", "C"]
                let role = roles[index % roles.count]
                return "\(role): \(line)"
            }
    }

    private static func stripMarkdownFence(_ output: String) -> String {
        var trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(
                of: #"^```(?:json)?\s*"#,
                with: "",
                options: .regularExpression
            )
            trimmed = trimmed.replacingOccurrences(
                of: #"\s*```$"#,
                with: "",
                options: .regularExpression
            )
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackSummary(from transcript: String) -> String {
        var points = fallbackSummaryPoints()
        let topicHint = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? ""

        if !topicHint.isEmpty {
            points[0] = "讨论核心围绕：\(topicHint.prefix(28))。"
        }
        return points.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func fallbackSummaryPoints() -> [String] {
        [
            "先确认本次讨论目标与边界，再推进执行。",
            "优先落地最小可行方案，复杂项后置。",
            "按优先级拆分下一步动作并明确负责人。"
        ]
    }

    private static func fallbackDialogue(from transcript: String) -> String {
        let lines = fallbackDialogueLines(from: transcript)
        return lines.joined(separator: "\n")
    }

    private static func fallbackDialogueLines(from transcript: String) -> [String] {
        let compact = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else {
            return ["A: （暂无有效转写内容）"]
        }

        let rawLines = compact
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let roles = ["A", "B", "C"]

        if rawLines.isEmpty {
            return ["A: \(compact)"]
        }

        return rawLines.enumerated().map { index, line in
            if line.range(of: #"^[A-Z][A-Z0-9]*\s*[:：]"#, options: .regularExpression) != nil {
                return line.replacingOccurrences(of: "：", with: ":")
            }
            return "\(roles[index % roles.count]): \(line)"
        }
    }
}
