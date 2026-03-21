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
}

struct SelectionRewriteResult: Equatable {
    let rewrittenText: String
    let actionLabel: String
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
    let providerID: SpeechProviderID
    let providerName: String
    let modelName: String
    let outputText: String
}

protocol TextGenerationProvider {
    var providerID: SpeechProviderID { get }
    var providerName: String { get }
    func generateText(
        request: TextGenerationRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> TextGenerationResult
}

protocol RewriteProvider {
    var providerID: SpeechProviderID { get }
    var providerName: String { get }
    func rewrite(
        request: SelectionRewriteRequest,
        configuration: TextGenerationProviderConfiguration,
        apiKey: String
    ) async throws -> SelectionRewriteResult
}

struct RewriteProviderRegistry {
    private let providersByID: [SpeechProviderID: any RewriteProvider]

    init(providers: [any RewriteProvider]) {
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.providerID, $0) })
    }

    func provider(for providerID: SpeechProviderID) -> (any RewriteProvider)? {
        providersByID[providerID]
    }
}

struct RewriteIntentParser {
    func parse(instruction: String) throws -> RewriteIntent {
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

        if lowercased.contains("正式") || lowercased.contains("formal") || lowercased.contains("润色") || lowercased.contains("polish") {
            return RewriteIntent(
                action: .polish(style: .formal),
                sourceInstruction: normalized
            )
        }

        if lowercased.contains("口语") || lowercased.contains("casual") || lowercased.contains("自然一点") {
            return RewriteIntent(
                action: .polish(style: .casual),
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

struct RewritePromptBuilder {
    func build(
        intent: RewriteIntent,
        request: SelectionRewriteRequest
    ) -> RewritePromptTemplate {
        let systemPrompt = """
        You are a precise text rewrite engine.
        Return only rewritten text with no explanations.
        Preserve core meaning unless instruction asks for transformation.
        """

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
    let providerID: SpeechProviderID = .openAI
    let providerName: String = SpeechProviderID.openAI.displayName

    private let generationProvider: TextGenerationProvider
    private let intentParser: RewriteIntentParser
    private let promptBuilder: RewritePromptBuilder

    init(
        generationProvider: TextGenerationProvider = OpenAITextGenerationProvider(),
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

        let intent = try intentParser.parse(instruction: request.spokenInstruction)
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
