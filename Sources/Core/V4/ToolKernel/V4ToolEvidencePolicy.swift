import Foundation

struct V4ToolEvidencePolicy: Sendable {
    func validate(
        output: V4ToolExecutionOutput,
        manifest: V4ToolManifest,
        toolID: String,
        errorCatalog: V4ToolErrorCatalog
    ) -> V4ToolError? {
        switch manifest.evidenceRequirement.level {
        case .none:
            return nil

        case .summary:
            guard !output.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "evidence summary missing for \(toolID)"
                )
            }
            return nil

        case .structured:
            guard !output.evidenceSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "structured evidence summary missing for \(toolID)"
                )
            }
            let object = output.rawPayload?.objectValue
            let summaryFields = parseEvidenceFields(output.evidenceSummary)
            let missingKeys = manifest.evidenceRequirement.requiredKeys.filter {
                if
                    let value = object?[$0],
                    !isMissingStructuredValue(value)
                {
                    return false
                }
                if let fallback = summaryFields[$0.lowercased()] {
                    return fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                return true
            }
            guard missingKeys.isEmpty else {
                return errorCatalog.missingEvidence(
                    toolID: toolID,
                    requirement: manifest.evidenceRequirement,
                    debugMessage: "structured evidence keys missing for \(toolID): \(missingKeys.joined(separator: ","))"
                )
            }
            return nil
        }
    }

    private func isMissingStructuredValue(_ value: V4ToolValue) -> Bool {
        switch value {
        case let .string(text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .null:
            return true
        default:
            return false
        }
    }

    private func parseEvidenceFields(_ evidenceSummary: String) -> [String: String] {
        evidenceSummary
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { $0 == ";" || $0 == "|" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce(into: [String: String]()) { partialResult, segment in
                guard !segment.isEmpty else {
                    return
                }
                for token in segment.split(whereSeparator: \.isWhitespace) {
                    let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else {
                        continue
                    }
                    let key = String(pair[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let value = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else {
                        continue
                    }
                    partialResult[key] = value
                }
            }
    }
}
