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

    static func defaultText(for entry: SessionHistoryEntry) -> String? {
        if entry.mode == .dictation {
            return primaryText(for: entry)
                ?? rawText(for: entry)
                ?? normalized(entry.errorMessage)
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
}
