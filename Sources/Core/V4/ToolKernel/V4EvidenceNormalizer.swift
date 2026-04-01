import Foundation

struct V4EvidenceNormalizer {
    func normalize(
        toolUse: V4ToolUse,
        status: V4ToolResultStatus,
        outputText: String?,
        evidenceLines: [String],
        rawPayload: V4ToolValue?,
        startedAt: Date,
        finishedAt: Date,
        error: V4ToolError?
    ) -> V4ToolResult {
        V4ToolResult(
            runID: toolUse.runID,
            stepID: toolUse.stepID,
            traceID: toolUse.traceID,
            lane: toolUse.lane,
            goalSummary: toolUse.goalSummary,
            toolName: toolUse.toolName,
            status: status,
            outputText: trimmedOrNil(outputText),
            evidenceSummary: normalizedEvidenceSummary(from: evidenceLines),
            rawPayload: encodedPayload(rawPayload),
            startedAt: startedAt,
            finishedAt: finishedAt,
            error: error
        )
    }

    func normalizedEvidenceSummary(from evidenceLines: [String]) -> String {
        var deduped = [String]()
        var seen = Set<String>()
        for line in evidenceLines {
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                continue
            }
            guard seen.insert(normalized).inserted else {
                continue
            }
            deduped.append(normalized)
        }
        return deduped.joined(separator: "\n")
    }

    private func trimmedOrNil(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func encodedPayload(_ payload: V4ToolValue?) -> String? {
        guard let payload else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
