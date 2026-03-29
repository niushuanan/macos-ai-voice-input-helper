import Foundation

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
