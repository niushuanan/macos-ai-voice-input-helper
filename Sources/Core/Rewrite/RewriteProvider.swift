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
            return "Translate -> \(targetLanguage)"
        case let .polish(style):
            return "Polish -> \(style.rawValue)"
        case .condense:
            return "Condense"
        case .structure:
            return "Structure"
        case .custom:
            return "Custom rewrite"
        }
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

protocol TextGenerationProvider {
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
            lowercased.contains("整理") ||
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

struct RewritePromptBuilder {
    func build(
        intent: RewriteIntent,
        request: SelectionRewriteRequest
    ) -> RewritePromptTemplate {
        var systemPrompt = """
        You are a precise text rewrite engine.
        Return only rewritten text with no explanations.
        Preserve core meaning unless instruction asks for transformation.
        """

        if
            let userSystemPrompt = request.userSystemPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !userSystemPrompt.isEmpty
        {
            systemPrompt += """

            User preference system instruction:
            \(userSystemPrompt)
            """
        }

        if
            let appPrompt = request.appPrompt?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !appPrompt.isEmpty
        {
            systemPrompt += """

            App-specific instruction:
            \(appPrompt)
            """
        }

        let actionInstruction: String
        switch intent.action {
        case let .translate(targetLanguage):
            actionInstruction = "Translate the selected text into \(targetLanguage). Keep names and numbers accurate."
        case let .polish(style):
            switch style {
            case .formal:
                actionInstruction = "Polish the text to be more formal and professional."
            case .casual:
                actionInstruction = "Polish the text to be more conversational and natural."
            case .neutral:
                actionInstruction = "Polish the text while keeping a neutral tone."
            }
        case .condense:
            actionInstruction = "Condense the text while preserving key meaning and important details."
        case .structure:
            actionInstruction = "Reorganize the text into a clear structured bullet list."
        case let .custom(command):
            actionInstruction = "Apply this rewrite instruction: \(command)"
        }

        let userPrompt = """
        App context:
        - appName: \(request.focusContext.appName)
        - bundleID: \(request.focusContext.bundleID)

        Spoken instruction:
        \(request.spokenInstruction)

        Action:
        \(actionInstruction)

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

struct OpenAIRewriteProvider: RewriteProvider {
    let supportedProviderTypes: [ProviderType] = [.openAI, .openAICompatible]

    private let generationProvider: any TextGenerationProvider
    private let intentParser: RewriteIntentParser
    private let promptBuilder: RewritePromptBuilder

    init(
        generationProvider: any TextGenerationProvider = OpenAITextGenerationProvider(),
        intentParser: RewriteIntentParser = RewriteIntentParser(),
        promptBuilder: RewritePromptBuilder = RewritePromptBuilder()
    ) {
        self.generationProvider = generationProvider
        self.intentParser = intentParser
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

        let intent = try intentParser.parse(
            instruction: request.spokenInstruction,
            defaultOutputBias: request.outputBias
        )
        let template = promptBuilder.build(
            intent: intent,
            request: request
        )

        let generation = try await generationProvider.generateText(
            request: TextGenerationRequest(
                systemPrompt: template.systemPrompt,
                userPrompt: template.userPrompt,
                temperature: 0.2,
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
            actionLabel: intent.action.label,
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
}

struct BrainstormContextComposeResult: Equatable {
    let outputText: String
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
        let systemPrompt = """
        You are an expert discussion organizer.
        Return only YAML.
        Do not add markdown fences.
        Keep content concise and factual.
        If speaker names are missing, use A/B/C.
        Keep the key order exactly:
        topic
        participants
        dialogue
        decision
        tradeoff
        open_questions
        next_actions
        ask_ai
        """

        let userPrompt = """
        App context:
        - appName: \(request.focusContext.appName)
        - bundleID: \(request.focusContext.bundleID)

        Raw transcript:
        <<<TEXT
        \(request.transcript)
        TEXT>>>

        Output rules:
        - dialogue should contain speaker-prefixed lines such as "A: ...".
        - decision/tradeoff/open_questions should be arrays.
        - next_actions should be an array of mapping items with owner/action/due keys.
        - ask_ai must be one short sentence asking for MVP, milestones, risks, and metrics.
        - Do not invent people names.
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
                focusContext: request.focusContext
            )
        )

        let dynamicTokenBudget = max(220, min(1200, normalized.count * 2))
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

        return BrainstormContextComposeResult(
            outputText: output,
            providerName: generation.providerName,
            modelName: generation.modelName
        )
    }
}
