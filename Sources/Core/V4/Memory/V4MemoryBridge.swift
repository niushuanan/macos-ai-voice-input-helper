import Foundation

struct V4MemoryBridge {
    func makeEntries(from historyEntries: [SessionHistoryEntry]) -> [V4MemoryEntry] {
        historyEntries.map(makeEntry(from:))
    }

    func makeEntry(from entry: SessionHistoryEntry) -> V4MemoryEntry {
        V4MemoryEntry(
            id: entry.id.uuidString,
            timestamp: entry.timestamp,
            lane: lane(from: entry.mode),
            appName: normalized(entry.appName),
            bundleID: normalized(entry.bundleID),
            moduleTags: moduleTags(from: entry),
            inputText: normalized(entry.inputText) ?? "",
            outputText: outputText(from: entry),
            instructionText: normalized(entry.instructionText) ?? "",
            goalSummary: goalSummary(from: entry),
            stepSummaries: entry.magicianStepSummaries ?? [],
            evidenceSummary: normalized(entry.magicianEvidenceSummary) ?? "",
            appliedSkills: entry.appliedSkills.map(\.rawValue),
            source: "history",
            traceID: normalized(entry.magicianRunID),
            sessionID: normalized(entry.magicianSessionID)
        )
    }

    private func lane(from mode: SessionHistoryMode) -> V4Lane {
        switch mode {
        case .dictation:
            return .directDictation
        case .selectionRewrite:
            return .selectionRewrite
        case .brainstorm:
            return .brainstormDiscussion
        }
    }

    private func outputText(from entry: SessionHistoryEntry) -> String {
        if let display = normalized(entry.displayText) {
            return display
        }
        if let output = normalized(entry.outputText) {
            return output
        }
        if let dialogue = normalized(entry.brainstormDialogueText) {
            return dialogue
        }
        if let error = normalized(entry.errorMessage) {
            return error
        }
        return ""
    }

    private func goalSummary(from entry: SessionHistoryEntry) -> String {
        if let value = normalized(entry.magicianGoalSummary) {
            return value
        }
        if let value = normalized(entry.instructionText) {
            return value
        }
        if let value = normalized(entry.displayText) {
            return value
        }
        if let value = normalized(entry.outputText) {
            return value
        }
        if let value = normalized(entry.inputText) {
            return value
        }
        return entry.mode.rawValue
    }

    private func moduleTags(from entry: SessionHistoryEntry) -> [String] {
        var tags: [String] = []

        switch entry.mode {
        case .dictation:
            tags.append("dictation")
        case .selectionRewrite:
            tags.append("magician")
        case .brainstorm:
            tags.append("brainstorm")
        }

        if let featureID = entry.magicianFeatureID?.rawValue {
            tags.append(featureID)
        }
        tags.append(contentsOf: entry.appliedSkills.map(\.rawValue))

        if entry.status == .failed {
            tags.append("failed")
        }

        var uniqueTags: [String] = []
        for tag in tags where !uniqueTags.contains(tag) {
            uniqueTags.append(tag)
        }
        return uniqueTags
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
