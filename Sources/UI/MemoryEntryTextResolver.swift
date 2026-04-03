import Foundation

enum MemoryEntryTextResolver {
    static func primaryText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .dictation else {
            return nil
        }
        return normalized(entry.outputText)
    }

    static func rawText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .dictation else {
            return nil
        }
        return normalizedRaw(entry.inputText)
    }

    static func brainstormSummaryText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .brainstorm else {
            return nil
        }
        return normalized(entry.outputText)
            ?? normalized(entry.errorMessage)
    }

    static func brainstormDialogueText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .brainstorm else {
            return nil
        }
        return normalized(entry.brainstormDialogueText)
    }

    static func brainstormRawText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .brainstorm else {
            return nil
        }
        return normalizedRaw(entry.inputText)
    }

    static func magicianPrimaryText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .selectionRewrite else {
            return nil
        }

        if entry.status == .failed {
            return sanitizedMagicianText(entry.displayText, entry: entry)
                ?? normalized(entry.errorMessage)
                ?? sanitizedMagicianText(entry.outputText, entry: entry)
                ?? normalized(entry.inputText)
        }

        return sanitizedMagicianText(entry.displayText, entry: entry)
            ?? sanitizedMagicianText(entry.outputText, entry: entry)
            ?? normalized(entry.errorMessage)
            ?? normalized(entry.inputText)
    }

    static func magicianSecondaryText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .selectionRewrite else {
            return nil
        }

        let source = normalizedRaw(entry.inputText)
        let primary = magicianPrimaryText(for: entry)
        guard let source else {
            return nil
        }
        return source == primary ? nil : source
    }

    static func magicianInstructionText(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .selectionRewrite else {
            return nil
        }
        return normalized(entry.instructionText)
    }

    static func magicianExecutionInterpretation(for entry: SessionHistoryEntry) -> String? {
        guard entry.mode == .selectionRewrite else {
            return nil
        }
        return normalized(entry.magicianExecutionInterpretation)
    }

    static func defaultText(for entry: SessionHistoryEntry) -> String? {
        if entry.mode == .dictation {
            return primaryText(for: entry)
                ?? rawText(for: entry)
                ?? normalized(entry.errorMessage)
        }

        if entry.mode == .selectionRewrite {
            return magicianPrimaryText(for: entry)
        }

        if entry.mode == .brainstorm {
            return brainstormSummaryText(for: entry)
                ?? brainstormDialogueText(for: entry)
                ?? brainstormRawText(for: entry)
                ?? normalized(entry.errorMessage)
        }

        return normalized(entry.outputText)
            ?? normalized(entry.inputText)
            ?? normalized(entry.errorMessage)
    }

    static func placeholder(for entry: SessionHistoryEntry) -> String {
        defaultText(for: entry) ?? "无文本内容"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedRaw(_ value: String?) -> String? {
        guard let text = normalized(value) else {
            return nil
        }
        let withoutMarkers = text.replacingOccurrences(
            of: #"<\|[^|>\n]{1,80}\|>"#,
            with: " ",
            options: .regularExpression
        )
        let compacted = withoutMarkers.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return normalized(compacted)
    }

    private static func sanitizedMagicianText(
        _ value: String?,
        entry: SessionHistoryEntry
    ) -> String? {
        guard var text = normalized(value) else {
            return nil
        }
        guard entry.mode == .selectionRewrite else {
            return text
        }
        guard let instruction = normalized(entry.instructionText) else {
            return text
        }

        let normalizedInstruction = instruction.trimmingCharacters(in: instructionTrimCharacterSet)
        let prefixes = [instruction, normalizedInstruction].filter { !$0.isEmpty }
        for prefix in prefixes {
            guard text.hasPrefix(prefix) else {
                continue
            }
            let stripped = String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: instructionTrimCharacterSet)
            if let normalizedStripped = normalized(stripped) {
                text = normalizedStripped
            }
            break
        }

        text = stripLegacyTemplateEnvelope(from: text)
        text = stripInstructionTemplatePrefix(text, instruction: instruction)

        if
            isLikelyInstructionPhrase(
                text,
                command: instruction,
                actionTokens: magicianActionTokens
            )
        {
            return nil
        }

        guard compact(text) != compact(instruction) else {
            return nil
        }
        return normalized(text)
    }

    private static func compact(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: instructionTrimCharacterSet)
            .joined()
    }

    private static func stripLegacyTemplateEnvelope(from text: String) -> String {
        var value = text
        let markers = [
            "来自 PulseType 魔术先生",
            "原文：",
            "指令：",
            "Spoken command:",
            "Selected text:",
            "<<<COMMAND",
            "COMMAND>>>"
        ]
        for marker in markers {
            guard let range = value.range(of: marker, options: [.caseInsensitive]) else {
                continue
            }
            let prefix = String(value[..<range.lowerBound])
                .trimmingCharacters(in: instructionTrimCharacterSet)
            if !prefix.isEmpty {
                value = prefix
                break
            }
            value = String(value[range.upperBound...])
                .trimmingCharacters(in: instructionTrimCharacterSet)
        }
        return value
    }

    private static func stripInstructionTemplatePrefix(
        _ text: String,
        instruction: String
    ) -> String {
        var value = text
        let normalizedInstruction = instruction.trimmingCharacters(in: instructionTrimCharacterSet)
        let candidates = [
            instruction,
            normalizedInstruction,
            "\(instruction)：",
            "\(instruction):",
            "\(instruction)。",
            "\(normalizedInstruction)：",
            "\(normalizedInstruction):",
            "\(normalizedInstruction)。"
        ].filter { !$0.isEmpty }

        for prefix in candidates {
            guard value.hasPrefix(prefix) else {
                continue
            }
            value = String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: instructionTrimCharacterSet)
            break
        }
        return value
    }

    private static let instructionTrimCharacterSet: CharacterSet = {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "，。；：、（）【】《》“”‘’「」『』—-"))
    }()

    private static let magicianActionTokens: [String] = [
        "帮我", "请", "一下", "帮忙", "把", "给我", "发给", "发送", "发邮件", "写邮件",
        "邮件", "草稿", "mail", "email", "备忘录", "note", "记到", "记下来", "记一下",
        "日程", "建立日程", "创建日程", "calendar", "event", "整理", "改写", "翻译"
    ]
}
