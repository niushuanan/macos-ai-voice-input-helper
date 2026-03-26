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
        return normalized(entry.inputText)
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
        return normalized(entry.inputText)
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

        let source = normalized(entry.inputText)
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

        guard compact(text) != compact(instruction) else {
            return nil
        }
        return text
    }

    private static func compact(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: instructionTrimCharacterSet)
            .joined()
    }

    private static let instructionTrimCharacterSet: CharacterSet = {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
            .union(CharacterSet(charactersIn: "，。；：、（）【】《》“”‘’「」『』—-"))
    }()
}
